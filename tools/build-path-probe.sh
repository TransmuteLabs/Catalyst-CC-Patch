#!/usr/bin/env bash
# The build-path probe: the one part of this kit the 119 checks cannot see.
#
# Every check in claude-patch-all.sh is a byte search over the FINISHED image, so
# all of them are blind to how that image came to be. The sweep across versions
# drives the pipeline through `--target`, which patches in place -- so the whole
# default-run branch (step 0b: notice the live binary already carries us, rebuild
# from the pristine copy into a staging file, swap it in by rename) has no
# coverage at all. Two regressions in that branch had already shipped by the time
# this probe was written: `PRISTINE_SRC="$BIN.orig"` naming a file that never
# exists on `--update`, and a version comparison that read tweakcc's second
# `--version` line and refused every default run. Neither was reachable from the
# sweep, and neither was visible to any check.
#
# So this drives the pipeline for real, three times, over throwaway copies:
#
#   a  live binary patched, a matching pristine `.orig` beside it
#      -> must stage, must swap in by RENAME (new inode: a running session keeps
#         executing the old one), must leave no staging file, and must not let
#         tweakcc's backup become a copy of our build.
#   b  live binary pristine, no `.orig` at all -- a first run on a clean machine
#      -> must ALSO stage, from the live bytes themselves, and must first keep
#         those bytes as `.orig`. Patching in place there was a hole of its own:
#         the live installation was the build for the whole run, so a gate that
#         fired late left the human with an image that had been patched and then
#         declared unfit, while the run reported a refusal.
#   c  the negative control: case (a) again, but against a copy of the pipeline
#      with 0b disabled entirely. At least one of case (a)'s assertions MUST go
#      red -- otherwise those assertions are decoration and this probe proves
#      nothing. The probe names which ones reddened.
#   d  the same control for case (b): 0b disabled, live binary pristine.
#   p  a `--target` run handed bytes that are NOT stock -> must refuse with code
#      4 BEFORE the unpacker and tweakcc's stage, and leave the named file
#      byte-for-byte as it was. Twice on 2026-08-28 it did not: a `--target` at
#      the live install had tweakcc restore its backup over patched bytes and
#      die FATAL, leaving the installation mutated, and a staging file a LATE
#      gate had refused over was still fed back in. Its control disables the
#      guard alone and stubs the first gate past it, so the walk past the site
#      costs seconds rather than a build.
#   u  the installer's own `--update` path, offline and in seconds: it must
#      build BESIDE the target and swap by rename, never download over the live
#      file. Its control is a copy of claude_patch.py with the staging removed.
#
# Case (c) runs a mutant copy of the pipeline out of a directory of symlinks to
# this kit, so nothing is written into the source tree; and it snapshots
# ~/.tweakcc/native-binary.backup first, because a mutant whose whole point is to
# hand tweakcc a patched image may well poison it -- that is the failure being
# demonstrated. The snapshot is restored on every exit path the shell can see --
# a normal end, a refusal, INT and TERM -- and a restore that FAILS is a refusal
# of the whole probe (non-zero) that also keeps the snapshots on disk, since they
# are then the only way back. SIGKILL runs no trap and is not covered: that case
# leaves the snapshots under the probe root, named in the line above.
#
# Exit codes -- the kit's shared table (see the top of claude-patch-all.sh):
#   0  green
#   1  a case went red, or an instrument of this probe (the lock probe, the
#      backup guard) says the kit is broken -- retrying will not help
#   2  the call contract is broken (unknown argument, unknown case letter, an
#      empty case set), OR an instrument of this probe cannot measure: the
#      lock preamble moved, the backup guard's carve anchor is gone. Both
#      say "there is nothing to measure yet", not "the kit is broken" --
#      different repairs, so they must not share a code
#   3  the pipeline lock is held by another live run -- retry later
#   5  nothing to measure ON THIS MACHINE (no patched install with a pristine
#      twin beside it) -- a skip, not a refusal
#   6  the lock machinery is broken (perl flock unusable): retrying will not help
#
# Death by signal is answered as 128+N (130 INT, 143 TERM, via the split
# traps) and is NOT a kit verdict -- POSIX reports the signal, this table
# reports the probe's answers. Declared for the two-sided rule (round 28, F-8).
# 130 arrives when INT is delivered to the process GROUP (what a terminal does
# on Ctrl-C); `kill -INT <script pid>` while a foreground child is alive is
# dropped by bash -- the child runs to completion, the trap does NOT fire, and
# the run finishes with its ordinary code. Nothing is truncated, so that code
# is honest; but probing 130 with a single-pid kill yields the false
# conclusion "the trap is broken" (measured, round 25, F-6).
# One code for two answers is what this split undoes: "wait for the lock" and
# "the kit is broken" used to share 3 (round 18, F-5).
#
# Called by tools/sweep.sh as a pre-flight, once per sweep: this branch is
# invisible to every check in the pipeline, and a tool nobody calls has been
# dead three times in this kit.
#
# Usage:  bash tools/build-path-probe.sh [--case abcdurxpl] [--version 2.1.247]
# Cost:   one full run per BUILD case (tweakcc + our patches + the pipeline's 119
#         checks + the interface gate + the bench), so a few minutes each; case
#         (r) and (x) build nothing and answer in milliseconds.

set -u

# Значения-истина: 1 true yes on (без учёта регистра). Ложь: пусто,
# отсутствие, 0 false no off. Всё прочее -- ОТКАЗ кодом 2 с именем ручки:
# в оболочке отказ дёшев и громок, а тихо выбранная сторона у ручки,
# меняющей измеряемое, -- это ровно тот дефект, который здесь чинится.
# В ядре, tweakcc-patch.js, та же семья решена иначе -- безопасная сторона
# плюс строка в журнал: там отказ убил бы живую сессию человека.
# Копии правила живут в tools/sweep.sh, tools/lock-probe.sh и
# claude-patch-all.sh; расхождение ловится сценарием стенда, а не чтением.
__envon() {  # имя переменной; 0 истина, 1 ложь, 2 неизвестное значение
  local __name="$1" __raw="${!1-}" __value
  __value=$(printf '%s' "$__raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  case "$__value" in
    1|true|yes|on) return 0 ;;
    ''|0|false|no|off) return 1 ;;
    *) echo "build-path-probe: ОТКАЗ -- $__name='$__raw', ожидается 1/true/yes/on или 0/false/no/off" >&2
       return 2 ;;
  esac
}
# Форма с `||`: см. claude-patch-all.sh -- `; rc=$?` под `set -e` обрывает молча.
__keep_root_rc=0
__envon KEEP_ROOT || __keep_root_rc=$?
(( __keep_root_rc != 2 )) || exit 2

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PIPELINE="$HERE/claude-patch-all.sh"
OUR_MARKER='baseURL:/^claude/i.test('
TWEAKCC_BACKUP="$HOME/.tweakcc/native-binary.backup"

VERSIONS="$HOME/.local/share/claude/versions"
CASES=abcdurxpl
WANT_VER=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --case)    CASES="${2:-}"; shift 2 ;;
    --version) WANT_VER="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; __DONE=1; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Пустой набор -- контракт вызова, а не зелёный прогон: `--case ''` крутил ноль
# итераций и печатал «every assertion held» (раунд 18, H-2).
if [[ -z "$CASES" ]]; then
  echo "build-path-probe: ОТКАЗ -- пустой набор случаев (--case '')" >&2
  echo "  Проверять нечего, а зелёная строка означала бы обратное." >&2
  exit 2
fi


ALL_CASES="$CASES"
case_l() {
  python3 - "$PIPELINE" <<'PY_LSOF'
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"(?ms)^versions_in_use\(\) \{\n.*?^\}\n", source)
if not match:
    print("  FAIL   L: versions_in_use() not found")
    raise SystemExit(1)
function = match.group(0)


def run(body, pgrep_body, lsof_body):
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        bindir = root / "bin"
        bindir.mkdir()
        for name, text in (("pgrep", pgrep_body), ("lsof", lsof_body)):
            path = bindir / name
            path.write_text("#!/usr/bin/env bash\n" + text, encoding="utf-8")
            path.chmod(0o755)
        script = "set -uo pipefail\n" + body + "\nversions_in_use\n"
        return subprocess.run(["bash"], input=script,
                              env={**os.environ, "PATH": str(bindir) + ":/usr/bin:/bin"},
                              capture_output=True, text=True)

space_path = "/Users/John Doe/.local/share/claude/versions/2.1.226"
foreign = "/foreign/process/2.1.999"
pgrep_one = "printf '123\\n'\n"
lsof_space = "printf 'p123\\nftxt\\nn%s\\n'\n" % space_path
lsof_empty = ":\n"
lsof_args = (
    "seen_a=0\n"
    "for arg in \"$@\"; do [[ \"$arg\" == -a ]] && seen_a=1; done\n"
    "if [[ $seen_a -eq 0 ]]; then\n"
    "  printf 'p616\\nftxt\\nn%s\\n'\n"
    "else\n"
    "  printf 'p123\\nftxt\\nn%s\\n'\n"
    "fi\n"
) % (foreign, space_path)
checks = [
    ("L1", run(function, pgrep_one, lsof_space),
     lambda r: r.returncode == 0 and r.stdout.splitlines() == [space_path]),
    ("L2", run(function, pgrep_one, lsof_empty),
     lambda r: r.returncode == 2 and not r.stdout),
    ("L3", run(function, ":\n", lsof_space),
     lambda r: r.returncode == 0 and not r.stdout),
    ("L4", run(function, pgrep_one, lsof_args),
     lambda r: r.returncode == 0 and foreign not in r.stdout and space_path in r.stdout),
]
failed = 0
for name, result, predicate in checks:
    if predicate(result):
        print("  ok     %s" % name)
    else:
        failed += 1
        print("  FAIL   %s rc=%s stdout=%r stderr=%r" %
              (name, result.returncode, result.stdout, result.stderr))

mutations = [
    ("L1-last-field", "sed -n 's/^n//p'", "awk '{print $NF}'", "L1"),
    ("L2-empty-is-safe", '[[ -n "$names" ]] || return 2',
     '[[ -n "$names" ]] || continue', "L2"),
    ("L3-empty-pgrep-refused", '[[ -z "$pids" ]] && return 0',
     '[[ -z "$pids" ]] && return 2', "L3"),
    ("L4-no-and-selector", "lsof -a -p", "lsof -p", "L4"),
]
for mutation, old, new, owner in mutations:
    if function.count(old) != 1:
        failed += 1
        print("  FAIL   mutation %s anchor count=%s" % (mutation, function.count(old)))
        continue
    mutated = function.replace(old, new, 1)
    if owner == "L1":
        result = run(mutated, pgrep_one, lsof_space)
        red = not (result.returncode == 0 and result.stdout.splitlines() == [space_path])
    elif owner == "L2":
        result = run(mutated, pgrep_one, lsof_empty)
        red = not (result.returncode == 2 and not result.stdout)
    elif owner == "L3":
        result = run(mutated, ":\n", lsof_space)
        red = not (result.returncode == 0 and not result.stdout)
    else:
        result = run(mutated, pgrep_one, lsof_args)
        red = not (result.returncode == 0 and foreign not in result.stdout and space_path in result.stdout)
    if red:
        print("  RED    mutation %s (%s)" % (mutation, owner))
    else:
        failed += 1
        print("  FAIL   mutation %s did not redden %s" % (mutation, owner))

print("build-path-probe L: сценариев=4 мутаций=4 расхождений=%d" % failed)
raise SystemExit(1 if failed else 0)
PY_LSOF
}

if [[ "$CASES" == *l* ]]; then
  case_l || exit $?
  CASES="${CASES//l/}"
  if [[ -z "$CASES" ]]; then
    echo "build path ($ALL_CASES): every assertion held, and the control shows they have teeth"
    exit 0
  fi
fi

# Замок берётся ПОСЛЕ разбора аргументов. Раньше он стоял выше, и `--help` во
# время свипа отвечал «конвейер уже работает» вместо текста использования --
# отказ там, где ничего разделять не нужно: аргументы читаются без единого
# касания общего состояния.
#
# А перед самим замком гоняется прибор замка. Зонд пути сборки опирается на то,
# что владение передаётся детям и держится всё его время; если этот механизм
# сломан, зонд молча измерял бы не то. Прибор дешёв (секунды), у него свой
# TMPDIR, настоящего замка он не касается. Заодно это единственный вызывающий
# прибора: инструмент, которого никто не зовёт, в этом ките уже трижды
# оказывался мёртвым, и за его тишиной каждый раз лежал дефект.
# Ответ прибора различается ПО КЛАССУ: «замок сломан» (1) и «мерить нечем --
# преамбула переехала» (2) чинятся по-разному, а прежде оба выходили кодом 3,
# который у этого зонда значит «занят замок конвейера, повторите позже»
# (раунд 18, F-5/F-6).
bash "$(dirname "$0")/lock-probe.sh"; __lp=$?
if (( __lp != 0 )); then
  if (( __lp == 2 )); then
    echo "ОТКАЗ: прибор замка не может мерить (преамбула переехала или не парсится)." >&2
    exit 2
  fi
  echo "ОТКАЗ: прибор замка не сошёлся -- не измеряю путь сборки на сломанном замке." >&2
  exit 1
fi

# По той же причине -- страж «цель против бэкапа tweakcc». Зонд трижды
# запускает конвейер по своим целям; если страж сломан в сторону ложного
# срабатывания, кейсы зонда упрутся в отказ и он измерит не то, а если в
# сторону молчания -- обе стороны будут зелены при подменённом входе. Проба
# ничего не собирает и настоящего бэкапа не касается: секунды.
# Ответ пробы различается ПО КЛАССУ, как и у прибора замка выше: «страж
# разошёлся с таблицей» (1) и «мерить нечем -- якорь вырезки пропал или случай
# объявлен без причины» (2) чинятся по-разному.
bash "$(dirname "$0")/backup-divergence-probe.sh"; __bd=$?
if (( __bd != 0 )); then
  if (( __bd == 2 )); then
    echo "ОТКАЗ: проба стража не может мерить (якорь вырезки пропал или случай без причины)." >&2
    exit 2
  fi
  # Круг 28, F-7: проба объявляет 6 (нет python3 -- вырезать стража нечем), а
  # вызывающий отделял только 2, и 6 читался как 1 «таблица стража не
  # сошлась» -- чужой класс и чужой текст. Рука -- по образцу соседней ветки
  # прибора замка выше: класс называется, повтор «не поможет».
  if (( __bd == 6 )); then
    echo "ОТКАЗ: машинерия пробы стража сломана (нет python3) -- не измеряю путь сборки." >&2
    exit 6
  fi
  # Красный страж -- сломанный кит, а не занятый замок: повтор не поможет.
  echo "ОТКАЗ: страж «цель против бэкапа» не сошёлся -- не измеряю путь сборки." >&2
  exit 1
fi

# ЗАМОК НА ВСЁ ВРЕМЯ ЗОНДА, а не внутри каждого дочернего прогона.
#
# Зонд одалживает ЖИВОЕ состояние `~/.tweakcc` -- снимает `config.json` и
# `native-binary.backup`, гоняет три полных прогона конвейера, восстанавливает.
# Замок конвейера закрывает только время самого прогона; между кейсами и на
# восстановлении его нет. В это окно настоящий прогон (или прямой tweakcc)
# законно обновляет backup шагом 1b и `ccVersion` в startupCheck -- а
# восстановление зонда, которое отличает «своя порча» от «чужая работа» только
# по `cmp`, откатывает и то и другое на снимок сорокаминутной давности.
# Последствие ровно то, ради обнаружения которого зонд написан: откаченный
# `ccVersion` заставляет следующий startupCheck освежить backup из
# УСТАНОВЛЕННОГО (пропатченного) бинаря -- отравление, диагностируемое много
# позже как «site not found».
#
# То же окно у seed_version_mismatch: он пишет живой конфиг ДО того, как
# ребёнок возьмёт замок, и способен лечь между `--list-patches` и `--apply`
# чужого прогона (каждый вызов tweakcc читает конфиг заново).
#
# Поэтому замок берётся ЗДЕСЬ и держится до выхода, а дочерние прогоны получают
# его по наследству через CLAUDE_PATCH_LOCK_HELD_BY: взяв замок заново, ребёнок
# встал бы против собственного родителя. Конвейер эту заявку проверяет, а не
# принимает на слово (см. его преамбулу).
# Ручка та же, что у конвейера и свипа. Зонд её НЕ читал и брал боевой файл:
# прогон, уведённый на отдельный замок, получал зонд, севший на замок соседа --
# то есть ровно ту встречную блокировку, против которой ручка и заведена.
# Форма выражения одна во всех четырёх домах и запинена стендом: преамбула
# конвейера обязана оставаться самодостаточной (lock-probe исполняет её
# ОТДЕЛЬНО, вырезав из файла), поэтому общий файл сюда не подключить.
LOCK_FILE="${CLAUDE_PATCH_LOCK:-${TMPDIR:-/tmp}/claude-patch-all.$(id -u).lock}"
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1 && flock -n 9; then
  :
elif perl -e '
      use Fcntl ":flock";
      open(my $fh, ">&=9") or exit 2;
      exit(flock($fh, LOCK_EX|LOCK_NB) ? 0 : 1);
    '; then
  :
else
  __rc=$?
  # «Занято» и «прибор не сработал» -- разные ответы, и второй нельзя читать как
  # первый: молчаливое продолжение без замка и есть тот вход, на котором зонд
  # откатывает чужую работу.
  if [[ $__rc -eq 1 ]]; then
    echo "ОТКАЗ: конвейер уже работает (замок $LOCK_FILE занят)." >&2
    echo "       Зонд одалживает живой ~/.tweakcc и рядом с ним идти не может." >&2
    echo "       Кто держит:  lsof $LOCK_FILE" >&2
    exit 3
  fi
  # Сломанная машинерия замка -- свой код: повторять бесполезно, и свип не
  # должен ждать бюджет замка на этом ответе (раунд 18, F-5).
  echo "ОТКАЗ: не удалось взять замок -- машинерия замка сломана (perl rc=$__rc)." >&2
  echo "       Без замка зонд откатит чужую работу на свой снимок -- не иду." >&2
  exit 6
fi
export CLAUDE_PATCH_LOCK_HELD_BY=$$

# `grep -c` prints 0 AND exits 1 when it finds nothing, so `|| echo 0`
# APPENDS a second line instead of substituting one: on a clean file the
# helper used to return "0\n0", which every comparison here read as "not
# zero". Take grep's own number when it is a number; a missing or unreadable
# file makes grep print nothing at all, and only that case defaults to 0.
marks() {
  local n
  n=$(grep -c -a -F "$OUR_MARKER" "$1" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

# The instrument is tested before it is trusted. This probe exists because
# an assertion that cannot fail looks exactly like an assertion that passes,
# and the helper above was itself an example: written in wave 8, it made
# every case skip and every negative-control line count as reddened, and
# nobody could see it until the probe was run for the first time.
self_test_marks() {
  local d yes no
  d="$(mktemp -d)"; yes="$d/yes"; no="$d/no"
  printf '%s\n' "prefix ${OUR_MARKER} suffix" > "$yes"
  printf '%s\n' "nothing to see here" > "$no"
  local a b c
  a="$(marks "$yes")"; b="$(marks "$no")"; c="$(marks "$d/absent")"
  rm -rf "$d"
  if [[ "$a" != 1 || "$b" != 0 || "$c" != 0 ]]; then
    echo "FATAL: marks() не различает помеченный и чистый файл (есть=$a нет=$b отсутствует=$c)" >&2
    exit 1
  fi
}
self_test_marks
# BSD stat and GNU stat spell the same question differently, and a probe whose
# central assertion is "the inode changed" must not report `none` on Linux
# because it asked in the wrong dialect -- that reads as "the file is gone".
inode() {
  [[ -f "$1" ]] || { echo "absent"; return 0; }
  stat -f%i "$1" 2>/dev/null || stat -c%i "$1" 2>/dev/null || echo "none"
}
# Отсутствие и «оба диалекта промолчали» -- РАЗНЫЕ ответы, и ни один из них не
# является инодом. Потребитель сравнивает ДО с ПОСЛЕ, поэтому обязан отвергать
# оба, а не радоваться неравенству.
is_inode() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
self_test_inode() {
  local t; t="$(mktemp)"
  is_inode "$(inode "$t")" || { echo "ПРОВАЛ самопроверки inode(): живой файл не дал инода" >&2; rm -f "$t"; exit 1; }
  rm -f "$t"
  is_inode "$(inode "$t")" && { echo "ПРОВАЛ самопроверки inode(): исчезнувший файл дал инод" >&2; exit 1; }
  return 0
}
self_test_inode

# --- material ----------------------------------------------------------------
# A patched build and a pristine copy of the SAME version. Both have to be real:
# a probe that fabricates its own inputs measures the fabrication. If they are
# not on this machine the probe SKIPS and says what is missing -- it does not
# quietly pass.
if [[ -z "$WANT_VER" ]]; then
  live="$(readlink "$HOME/.local/bin/claude" 2>/dev/null || true)"
  WANT_VER="$(basename "${live:-}")"
fi
PATCHED="$VERSIONS/$WANT_VER"
PRISTINE="$VERSIONS/$WANT_VER.orig"
# «Нет материала» и «не могу мерить» -- РАЗНЫЕ ответы, и второй нельзя читать
# как первый. Оба уезжали кодом 3, а его же отдаёт занятый замок и красный
# прибор: вызывающий (предполёт свипа) не мог отличить «на этой машине нечего
# мерить» от «механизм сломан», и любая политика по коду 3 была бы неверна для
# одной из сторон. Материал -- 5, отказы остаются на 3.
if [[ -z "$WANT_VER" || ! -f "$PATCHED" || ! -f "$PRISTINE" ]]; then
  echo "SKIP: need both $PATCHED and $PRISTINE" >&2
  echo "  (install a version with: bash claude-patch-all.sh --update <version>)" >&2
  exit 5
fi
if [[ "$(marks "$PATCHED")" == 0 ]]; then
  echo "SKIP: $PATCHED does not carry our patches, so case (a) has nothing to preserve" >&2
  exit 5
fi
if [[ "$(marks "$PRISTINE")" != 0 ]]; then
  echo "SKIP: $PRISTINE is not pristine -- it carries our marker" >&2
  exit 5
fi

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cc-build-path-probe.XXXXXX")"
BACKUP_SNAP="$ROOT/native-binary.backup.snapshot"
[[ -f "$TWEAKCC_BACKUP" ]] && cp -p "$TWEAKCC_BACKUP" "$BACKUP_SNAP"
TWEAKCC_CFG="$HOME/.tweakcc/config.json"
CFG_SNAP="$ROOT/config.json.snapshot"
# Три состояния, а не два: конфиг был и снят в снимок; конфига не было и его
# создаст сам зонд (тогда после прогона файл надо УБРАТЬ, а не «восстановить»);
# конфиг был, но снять не удалось. Без третьего флага зонд, создавший конфиг на
# чистой машине, оставлял бы его человеку навсегда.
CFG_WAS_ABSENT=0
if [[ -f "$TWEAKCC_CFG" ]]; then
  cp -p "$TWEAKCC_CFG" "$CFG_SNAP"
else
  CFG_WAS_ABSENT=1
fi

# Часовой оборванного прогона: bash 3.2 отдаёт код 0, когда скрипт с
# EXIT-трапом умирает на фатальной ошибке ПОДСТАНОВКИ (unbound variable под
# `set -u`, `${x:?}`, bad substitution) -- провал невидим вызывающему
# (измерено 2026-08-28). Штатный конец объявляет себя, трап без объявления
# краснит сам.
__DONE=0
__RESTORE_FAILED=0

# Возврат одного заимствованного файла. ОДНА реализация на оба файла и на зуб
# (случай r): копия кода в контроле рано или поздно разошлась бы с боевой, и
# зелёный зуб доказывал бы копию.
#
# Частичный `.probe-restore` убирается ЗДЕСЬ: `cp -p`, упавший на ENOSPC,
# оставляет полуфайл рядом с ЖИВЫМ конфигом tweakcc, и следующий читатель
# каталога видит мусор, которого никто не создавал намеренно (раунд 19, В-12).
restore_one() {   # <снимок> <живой путь>; 0 -- восстановлено либо не требовалось
  local snap="$1" live="$2"
  [[ -f "$snap" ]] || return 0
  cmp -s "$snap" "$live" 2>/dev/null && return 0
  if cp -p "$snap" "$live.probe-restore" && mv "$live.probe-restore" "$live"; then
    echo "restored $live from the probe's snapshot"
    return 0
  fi
  rm -f "$live.probe-restore"
  echo "WARNING: could not restore $live from $snap" >&2
  return 1
}

cleanup() {
  __rc=$?
  # Restore the borrowed config first: it carries the seeded version, and leaving
  # a bogus one behind makes the next real tweakcc run refresh its backup from
  # whatever binary happens to be installed -- the exact poisoning this probe is
  # about, caused by the probe.
  if [[ "${CFG_WAS_ABSENT:-0}" == "1" ]]; then
    # Конфига до зонда не было. Восстанавливать нечего -- надо убрать свой,
    # иначе зонд оставляет человеку файл с ccVersion=0.0.0-probe, то есть ровно
    # ту рассинхронизацию, ради обнаружения которой он его и завёл.
    if [[ -f "$TWEAKCC_CFG" ]]; then
      rm -f "$TWEAKCC_CFG" && echo "removed $TWEAKCC_CFG (the probe created it; there was none before)"
    fi
  else
    restore_one "$CFG_SNAP" "$TWEAKCC_CFG" || __RESTORE_FAILED=1
  fi
  # Restore the borrowed backup before anything else, and SAY whether it worked:
  # a silent failure here leaves the human with a poisoned tweakcc restore and no
  # idea this probe was the cause.
  restore_one "$BACKUP_SNAP" "$TWEAKCC_BACKUP" || __RESTORE_FAILED=1

  # Невозвращённое ЖИВОЕ состояние -- отказ прогона, а не примечание в логе.
  #
  # Прежде обе ветки провала печатали WARNING и не трогали код возврата: зонд,
  # у которого все случаи сошлись, выходил НУЛЁМ с подменённым бэкапом
  # ~/.tweakcc, а свип печатал «зонд пути сборки: ЗЕЛЁНО», не читая лога. Следом
  # тот же cleanup сносил $ROOT -- ЕДИНСТВЕННЫЙ источник ремонта (снимки
  # конфига и бэкапа). Ровно этим ремонтом чинился инцидент 2026-08-28, и
  # ровно его прежняя редакция делала невозможным (раунд 19, В-1 и В-2).
  if (( __RESTORE_FAILED )); then
    KEEP_ROOT=1
    echo "build-path-probe: ЖИВОЕ СОСТОЯНИЕ tweakcc НЕ ВОССТАНОВЛЕНО." >&2
    echo "  Снимки оставлены -- восстановить руками:" >&2
    [[ -f "$CFG_SNAP" ]]    && echo "    cp -p $CFG_SNAP $TWEAKCC_CFG" >&2
    [[ -f "$BACKUP_SNAP" ]] && echo "    cp -p $BACKUP_SNAP $TWEAKCC_BACKUP" >&2
    (( __rc == 0 )) && __rc=1
  fi

  # Держатель случая (x): переживает зонд на ~119 c и держит то, что
  # унаследовал или занял сам. Штатные ветки case_x снимают его не на всех
  # выходах -- сигнал посреди случая оставлял сироту с замком в руках.
  if [[ -n "${__CLI_HOLDER:-}" ]] && kill -0 "$__CLI_HOLDER" 2>/dev/null; then
    kill "$__CLI_HOLDER" 2>/dev/null
    wait "$__CLI_HOLDER" 2>/dev/null
  fi

  if ! __envon KEEP_ROOT; then
    rm -rf "$ROOT"
  fi
  if [[ "${__DONE:-0}" != 1 && "$__rc" == 0 ]]; then
    echo "build-path-probe: ОТКАЗ -- прогон оборвался, не дойдя до конца (ошибка оболочки выше)" >&2
    exit 1
  fi
  exit "$__rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Драйвер случая (u) пишется на диск здесь, а не встраивается в тело функции:
# его надо запустить ДВАЖДЫ -- по киту дерева и по мутированной копии, -- и обе
# половины обязаны исполнять ОДИН И ТОТ ЖЕ текст, иначе контроль сравнивает
# разные приборы.
cat > "$ROOT/update-probe.py" <<'UPDATE_PROBE'
"""Куда пишет `claude_patch.py --update`: в живой файл или рядом с ним.

Сеть и настоящий патч заменены заглушками -- измеряется не содержимое сборки, а
ИМЯ ФАЙЛА, в который пишет каждый шаг. Аргумент -- каталог с claude_patch.py
(дерево кита или мутированная копия).
"""
import os
import shutil
import sys
import tempfile
from pathlib import Path

kit = sys.argv[1]
sys.path.insert(0, kit)
import claude_patch as m

LIVE = b'PRISTINE-STOCK-IMAGE-no-patches'
FRESH = b'FRESH-STOCK-BYTES-FROM-REGISTRY'
BUILT = b'PATCHED-BYTES-with-marker-' + m.ROUTING_MARKER

failed = []


def probe(patch_works):
    root = Path(tempfile.mkdtemp(prefix='update-probe.'))
    try:
        vdir = root / 'versions'
        vdir.mkdir()
        target = vdir / '0.0.900'
        target.write_bytes(LIVE)
        repointed = []

        m.versions_dir = lambda: vdir
        m.download_binary = lambda version, dest: Path(dest).write_bytes(FRESH)
        m.repoint_launcher = lambda t: repointed.append(Path(t))

        def fake_patch(t, backup=None):
            if not patch_works:
                raise RuntimeError('патч упал (так и задумано)')
            Path(t).write_bytes(BUILT)
        m.patch_binary = fake_patch

        try:
            m.main(['--update', '0.0.900'])
            crashed = None
        except BaseException as e:          # SystemExit тоже
            crashed = repr(e)

        now = target.read_bytes()
        orig = vdir / '0.0.900.orig'
        staging_orig = vdir / '0.0.900.staging.orig'
        staging = vdir / '0.0.900.staging'
        if patch_works:
            if crashed:
                failed.append('успешный патч, а прогон упал: %s' % crashed)
            if now != BUILT:
                failed.append('цель не получила собранные байты (%r)' % now[:40])
            if staging.exists():
                failed.append('стадия осталась на диске: %s' % staging.name)
            if repointed != [target]:
                failed.append('лаунчер переведён не на цель: %r' % repointed)
        else:
            if not crashed:
                failed.append('патч упал, а прогон объявил успех')
            if now != LIVE:
                failed.append('ЖИВОЙ ФАЙЛ ПЕРЕПИСАН при упавшем патче: %r' % now[:40])
            if repointed:
                failed.append('лаунчер переведён при упавшем патче: %r' % repointed)
        if not orig.exists():
            failed.append('пристинная копия .orig не создана')
        elif orig.read_bytes() != FRESH:
            failed.append('.orig не из байт реестра: %r' % orig.read_bytes()[:40])
        if staging_orig.exists():
            failed.append('создана вторая копия под именем стадии: %s' % staging_orig.name)
    finally:
        shutil.rmtree(root, ignore_errors=True)


probe(patch_works=False)
probe(patch_works=True)
if failed:
    for f in failed:
        print('ПРОВАЛ ' + f)
    sys.exit(1)
print('ok --update строит рядом с целью и подменяет переименованием')
UPDATE_PROBE

FAILED=0
note()  { printf '  %-6s %s\n' "$1" "$2"; }
ok()    { note 'ok'   "$1"; }
bad()   { note 'FAIL' "$1"; FAILED=$((FAILED+1)); }

# Every case gets its own bin/ so PATH holds exactly one image and the
# recognizer's "exactly one" rule is satisfied by construction.
stage_dir() {
  local d="$ROOT/$1/bin"
  rm -rf "$ROOT/$1"; mkdir -p "$d"
  echo "$d"
}
# tweakcc's startupCheck refreshes its backup from `ccInstallationPath` only
# when the recorded version differs from the installed one. Without a mismatch
# the backup is never rewritten, so "the backup is still stock" holds in every
# case for a reason that has nothing to do with what is being tested -- and the
# control could not redden it no matter what it disabled. Seeded before EVERY
# run, because tweakcc records the real version once it refreshes and would not
# fire a second time.
seed_version_mismatch() {
  # Прежняя форма молча возвращалась, если конфига нет: `[[ -f ... ]] || return 0`.
  # На машине без конфига seed не срабатывал НИКОГДА, а значит утверждение
  # «бэкап всё ещё штатный» держалось по причине, не связанной с предметом
  # проверки, и отрицательный контроль не мог его покраснить -- при этом зонд
  # всё равно печатал, что контроль показал зубы.
  #
  # Отсутствие конфига -- не причина не мерить: tweakcc читает его как
  # `{...defaultConfig, ...JSON.parse(content)}` (src/config.ts:253), поэтому
  # файл из одного ключа законен, а после прогона он убирается (CFG_WAS_ABSENT).
  mkdir -p "$(dirname "$TWEAKCC_CFG")"
  [[ -f "$TWEAKCC_CFG" ]] || printf '{}\n' > "$TWEAKCC_CFG"
  python3 - "$TWEAKCC_CFG" <<'PY'
import json, os, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg['ccVersion'] = '0.0.0-probe'
# The LIVE config of the person running this probe. Staged and renamed: the
# probe's restore runs from a trap, and a trap does not run on SIGKILL, so a
# torn write here would outlive the probe.
tmp = p + '.probe-new'
with open(tmp, 'w', encoding='utf-8') as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
os.replace(tmp, p)
PY
}

run_pipeline() {  # <script> <bindir> <logfile> [аргументы конвейера...]
  seed_version_mismatch
  # Люки конвейера снимаются на запуске: зонд обязан мерить КИТ, а не среду
  # оператора. Тот же список и то же основание, что у свипа (раунд 19, В-5).
  ( PATH="$2:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES= CLAUDE_PATCH_SKIP_BENCH= \
    CLAUDE_PATCH_GATE_BUDGET= CLAUDE_PATCH_SIGN_ID= TWEAKCC_LOCAL= \
    CATALYST_TWEAKCC_REPO= CATALYST_TWEAKCC_SHA= \
    # Объявленный пропуск: каждая сборка зонда идёт без sync цен, и это
    # снятое покрытие (раунд 18, G-1). Строка печатается зондом, а не только
    # прячется в логе случая.
    CLAUDE_PATCH_SKIP_MODELS=1 bash "$1" "${@:4}" ) >"$3" 2>&1
}

# --- case a: live patched, pristine copy beside it ---------------------------
case_a() {
  local d log rc ino_before ino_after
  d="$(stage_dir a)"; log="$ROOT/a.log"
  cp -p "$PATCHED"  "$d/claude"
  cp -p "$PRISTINE" "$d/claude.orig"
  ino_before="$(inode "$d/claude")"
  echo "case a: live binary patched, pristine copy beside it"
  run_pipeline "$PIPELINE" "$d" "$log"; rc=$?
  ino_after="$(inode "$d/claude")"

  [[ $rc -eq 0 ]] && ok "pipeline finished (rc=0)" || bad "pipeline exited rc=$rc (see $log)"
  grep -q 'rebuilding from the pristine copy' "$log" \
    && ok 'took the staging branch' || bad 'never announced the staging branch'
  # Неравенство инодов -- утверждение о ДВУХ существующих файлах. Ответ
  # "absent"/"none" не инод, и пропускать его как «изменился» значит
  # засчитывать исчезновение бинарника за успешную подмену.
  if ! is_inode "$ino_before" || ! is_inode "$ino_after"; then
    bad "инод не измерен (до=$ino_before после=$ino_after): файла нет или stat промолчал"
  elif [[ "$ino_before" != "$ino_after" ]]; then
    ok "swapped in by rename (inode $ino_before -> $ino_after)"
  else
    bad "same inode $ino_after: patched in place, under any running session"
  fi
  [[ -e "$d/claude.staging" ]] \
    && bad 'left a staging file behind' || ok 'no staging file left behind'
  [[ "$(marks "$d/claude")" != 0 ]] \
    && ok 'the build that landed carries our patches' \
    || bad 'the build that landed carries NO patches'
  # `marks` answers 0 for a stock file AND for one that is not there (its own
  # self-test asserts exactly that), so testing only the count lets ABSENCE pass
  # as cleanliness. After a full pipeline run the backup exists -- tweakcc makes
  # it -- and its disappearance is its own finding, with its own words.
  if [[ ! -f "$TWEAKCC_BACKUP" ]]; then
    bad "tweakcc's backup is GONE -- there is nothing to restore from"
  elif [[ "$(marks "$TWEAKCC_BACKUP")" == 0 ]]; then
    ok "tweakcc's backup is still stock"
  else
    bad "tweakcc's backup now holds OUR build -- --restore would hand out patched bytes"
  fi
}

# --- case b: nothing to preserve ---------------------------------------------
case_b() {
  local d log rc ino_before ino_after
  d="$(stage_dir b)"; log="$ROOT/b.log"
  cp -p "$PRISTINE" "$d/claude"
  ino_before="$(inode "$d/claude")"
  echo "case b: live binary pristine, no copy beside it"
  run_pipeline "$PIPELINE" "$d" "$log"; rc=$?
  ino_after="$(inode "$d/claude")"

  [[ $rc -eq 0 ]] && ok "pipeline finished (rc=0)" || bad "pipeline exited rc=$rc (see $log)"
  grep -q 'building beside it into' "$log" \
    && ok 'took the staging branch from the live bytes' \
    || bad 'patched the live file in place -- a late gate would leave it half-built'
  if ! is_inode "$ino_before" || ! is_inode "$ino_after"; then
    bad "инод не измерен (до=$ino_before после=$ino_after): файла нет или stat промолчал"
  elif [[ "$ino_before" != "$ino_after" ]]; then
    ok "swapped in by rename (inode $ino_before -> $ino_after)"
  else
    bad "same inode $ino_after: patched in place, under any running session"
  fi
  [[ -e "$d/claude.staging" ]] \
    && bad 'left a staging file behind' || ok 'no staging file left behind'
  # Пристинные байты не должны исчезнуть вместе с подменой: `.orig` -- это то,
  # из чего пересобирает следующий прогон по умолчанию и что чинит бэкап
  # tweakcc. На чистой машине его раньше не появлялось вовсе, и ВТОРОЙ прогон
  # отказывал с «нет пристинной копии рядом».
  if [[ ! -f "$d/claude.orig" ]]; then
    bad 'pristine bytes are gone: no .orig beside the build'
  elif [[ "$(marks "$d/claude.orig")" != 0 ]]; then
    bad '.orig carries our patches -- it is not a pristine copy'
  else
    ok 'the live pristine bytes were kept as .orig'
  fi
  [[ "$(marks "$d/claude")" != 0 ]] \
    && ok 'the build carries our patches' || bad 'the build carries NO patches'
}

# --- case c: the negative control --------------------------------------------
# The mutation is named, minimal and faithful: 0b's trigger is forced false, so
# the pipeline hands tweakcc the live patched image exactly as it did before 0b
# existed. Everything else -- including 1b's repair of the backup and the
# post-stage assertion -- is left alone, because the point is to prove case (a)'s
# assertions detect THIS, not to disable the whole file.
case_c() {
  local d log rc ino_before ino_after kit reddened=0
  kit="$ROOT/kit"; mkdir -p "$kit"
  # A directory of symlinks: `dirname "$0"` inside the pipeline must resolve to
  # something that has tweakcc-patch.js, tools/ and judge/ beside it, and the
  # source tree must stay untouched.
  local f
  for f in "$HERE"/* "$HERE"/.[!.]*; do
    [[ -e "$f" ]] || continue
    ln -sfn "$f" "$kit/$(basename "$f")"
  done
  rm -f "$kit/claude-patch-all.sh"
  # Anchored to 0b's OUTER condition -- the line that decides whether a default
  # run stages at all. Both branches inside it (live patched -> from `.orig`,
  # live pristine -> from the live bytes) are disabled by this one edit, which
  # is exactly the state the pipeline was in before this wave.
  #
  # The anchor is the whole line, so a rewrite that touches a second guard shows
  # up as a changed-line count and refuses. Faithfulness of a mutation is not a
  # matter of intent: it is counted.
  sed -E 's/^if \[\[ -z "\$TARGET" && \$DO_UPDATE -eq 0 && \$ONLY_OURS -eq 0 \]\]; then$/if false; then/' \
    "$PIPELINE" > "$kit/claude-patch-all.sh"
  local changed
  changed=$(diff "$PIPELINE" "$kit/claude-patch-all.sh" | grep -c '^< ' || true)
  case "$changed" in ''|*[!0-9]*) changed=0 ;; esac
  if [[ "$changed" -eq 0 ]]; then
    bad 'the mutation did not apply -- 0b no longer has the expected trigger, so this control proves nothing'
    return
  fi
  if [[ "$changed" -ne 1 ]]; then
    bad "the mutation rewrote $changed lines, not 1 -- it is disabling more than 0b, so nothing it shows is about 0b"
    return
  fi

  d="$(stage_dir c)"; log="$ROOT/c.log"
  cp -p "$PATCHED"  "$d/claude"
  cp -p "$PRISTINE" "$d/claude.orig"
  ino_before="$(inode "$d/claude")"
  echo "case c (negative control): same as (a), with 0b's trigger forced false"
  run_pipeline "$kit/claude-patch-all.sh" "$d" "$log"; rc=$?
  ino_after="$(inode "$d/claude")"

  # The REQUIRED red is named, and it is the one 0b is: without 0b the pipeline
  # cannot announce a staging rebuild. Counting "at least one" let any mutant
  # that merely crashes the pipeline -- a syntax error, a missing bun, an
  # unrelated guard tripping -- pass as proof about the staging branch.
  local required=0
  grep -q 'rebuilding from the pristine copy' "$log" || { required=1; note 'red' 'staging branch not taken'; }
  if ! is_inode "$ino_before" || ! is_inode "$ino_after"; then
    note 'info' "инод не измерен (до=$ino_before после=$ino_after) -- не засчитано"
  elif [[ "$ino_before" == "$ino_after" ]]; then
    reddened=$((reddened+1)); note 'red' "patched in place (inode $ino_after)"
  fi
  [[ "$(marks "$TWEAKCC_BACKUP")" != 0 ]] && { reddened=$((reddened+1)); note 'red' "tweakcc's backup poisoned"; }
  # Reported, never counted: a pipeline that refused says nothing about which
  # assertion has teeth, and it is the most likely way a future mutation goes
  # wrong without anyone noticing.
  [[ $rc -ne 0 ]] && note 'info' "pipeline refused (rc=$rc) -- not counted as evidence"

  if [[ $required -eq 1 ]]; then
    ok "the mutation reddens the staging assertion, and $reddened more of case (a)'s"
  else
    bad 'the mutation changed NOTHING about the staging branch: case (a) is not testing 0b'
  fi
}

# --- case d: the negative control for case (b) -------------------------------
# Case (c) proves case (a)'s assertions have teeth on the PATCHED-live branch.
# The pristine-live branch is separate code with its own assertions, so it needs
# its own control -- otherwise "the default run always stages" is proven for one
# half and asserted for the other.
case_d() {
  local d log rc ino_before ino_after kit reddened=0 required=0
  kit="$ROOT/kit"
  if [[ ! -f "$kit/claude-patch-all.sh" ]]; then
    bad 'case (d) needs the mutant kit built by case (c) -- run them together (--case cd)'
    return
  fi
  d="$(stage_dir d)"; log="$ROOT/d.log"
  cp -p "$PRISTINE" "$d/claude"
  ino_before="$(inode "$d/claude")"
  echo "case d (negative control): same as (b), with 0b disabled"
  run_pipeline "$kit/claude-patch-all.sh" "$d" "$log"; rc=$?
  ino_after="$(inode "$d/claude")"

  grep -q 'building beside it into' "$log" || { required=1; note 'red' 'staging branch not taken'; }
  if ! is_inode "$ino_before" || ! is_inode "$ino_after"; then
    note 'info' "инод не измерен (до=$ino_before после=$ino_after) -- не засчитано"
  elif [[ "$ino_before" == "$ino_after" ]]; then
    reddened=$((reddened+1)); note 'red' "patched in place (inode $ino_after)"
  fi
  [[ -f "$d/claude.orig" ]] || { reddened=$((reddened+1)); note 'red' 'pristine bytes not kept'; }
  [[ $rc -ne 0 ]] && note 'info' "pipeline refused (rc=$rc) -- not counted as evidence"

  if [[ $required -eq 1 ]]; then
    ok "the mutation reddens case (b)'s staging assertion, and $reddened more"
  else
    bad 'the mutation changed NOTHING about the pristine-live branch: case (b) is not testing 0b'
  fi
}

# --- case u: the installer's own --update path -------------------------------
# Offline and in seconds: the network fetch and the byte patch are both replaced
# by stubs, because what is being measured is WHICH FILE each step writes to.
#
# The defect this exists for: `--update` downloaded straight into the target. If
# the requested version was the installed one and merely unpatched (a restore,
# an interrupted run, a fresh image), the launcher's own file was truncated and
# refilled over the network -- and a run that died in that window left the
# installation broken for good. patch_binary has staged its write since the
# beginning; the download was the one step that still wrote through the live
# name.
# --- страж разбираемости жертвы (круг 28, F-14) --------------------------------
# Зонд правит жертвы текстовой подменой, и замена могла сломать РАЗБОР жертвы:
# контроль красился бы синтаксической ошибкой, доказывая не отсутствие
# проверяемого механизма, а испорченный прибор (та же дыра, что полоса E
# закрыла у пяти стендов). Форма стража переиспользована из
# tools/corpus-tools-bench.sh (python_heredoc_bodies + sh_victim_parses),
# второй экземпляр правила не изобретался. Правило открытия -- то же, что у
# гейта PYCOMPILE конвейера: часть строки до первого '#' содержит python3
# границей слова, между python3 и открытием нет '|' ';' '&', строка КОНЧАЕТСЯ
# открытием <<'ТЕГ'; тело -- до строки, равной ТЕГУ дословно. Хвост после
# тега отсекает упоминания в комментариях и примерах -- иначе строка-пример
# проглотила бы хвост файла как «тело». Провал любого звена -- ненулевой
# возврат; вызывающий переводит его в код 2 «прибор не может мерить».
python_heredoc_bodies() {   # файл-жертва, каталог для тел; печатает число тел
  local f="$1" out="$2" line pre rest mid tag n=0
  local OPEN_RE="<<'([A-Za-z_][A-Za-z0-9_]*)'[[:space:]]*\$"
  tag=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$tag" ]]; then
      if [[ "$line" == "$tag" ]]; then tag=''; continue; fi
      printf '%s\n' "$line" >> "$out/body.$n.py"
      continue
    fi
    pre=${line%%#*}
    [[ "$pre" == *python3* ]] || continue
    [[ "$pre" =~ (^|[^A-Za-z0-9_])python3([^A-Za-z0-9_]|$) ]] || continue
    rest=${pre#*python3}
    mid=${rest%<<*}
    [[ "$mid" == *[\|\;\&]* ]] && continue
    [[ "$pre" =~ $OPEN_RE ]] || continue
    tag=${BASH_REMATCH[1]}
    n=$((n+1)); : > "$out/body.$n.py"
  done < "$f"
  printf '%s\n' "$n"
}

victim_parses() {   # файл-жертва: .py -- py_compile; .sh -- bash -n и тела heredoc
  local f="$1" dir n i
  case "$f" in
    *.py)
      python3 -c 'import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)' \
        "$f" >/dev/null 2>&1 || return 2
      return 0 ;;
  esac
  bash -n "$f" 2>/dev/null || return 2
  dir=$(mktemp -d "${TMPDIR:-/tmp}/heredoc.XXXXXX") || return 2
  n=$(python_heredoc_bodies "$f" "$dir")
  # BSD seq при пустом диапазоне (seq 1 0) печатает «1 0» ВНИЗ, а не пустоту:
  # без этой проверки страж гонял бы py_compile по несуществующим файлам и
  # краснел на жертвах без питоньих тел (замерено на этой машине).
  if (( n > 0 )); then
    for i in $(seq 1 "$n"); do
      python3 -m py_compile "$dir/body.$i.py" 2>/dev/null || { rm -rf "$dir"; return 2; }
    done
  fi
  rm -rf "$dir"
  return 0
}

case_u() {
  local out rc mut
  echo "case u: claude_patch.py --update builds beside the target"
  out="$(python3 "$ROOT/update-probe.py" "$HERE" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  [[ $rc -eq 0 ]] && ok 'the --update path never writes through the live name' \
                  || bad "the --update path wrote through the live name (see above)"

  # Отрицательный контроль: копия установщика без стадии. Утверждение обязано
  # покраснеть -- иначе оно ничего не проверяет.
  # Кит копии -- ПОЛНЫЙ: `main()` первым делом требует patch_claude_routing.py
  # рядом с собой, и копия из одного файла краснела с чужой причиной («нет
  # patch_claude_routing.py»), то есть доказывала сломанный прибор, а не
  # отсутствие стадии.
  mut="$ROOT/mutkit"; mkdir -p "$mut"
  cp "$HERE/claude_patch.py" "$HERE/patch_claude_routing.py" "$mut/"
  python3 - "$mut/claude_patch.py" <<'MUT'
import sys

p = sys.argv[1]
t = open(p, encoding='utf-8').read()
# Якорь НАЧИНАЕТСЯ С ПЕРЕВОДА СТРОКИ, и это не украшение: тот же оператор есть
# в ветке --download-only с отступом в 12 пробелов, а поиск по восьми пробелам
# -- ЕГО ПОДСТРОКА. Первая редакция контроля так и села на чужую ветку: мутация
# «применилась», прогон вёл себя как исправный, и контроль объявил утверждение
# беззубым, ничего о нём не измерив.
# Волна 31 (L-7): промежуточные имена получили pid писателя -- фиксированное
# имя стадии делили два одновременных прогона. Якорь догнан за формой; сама
# дисциплина «перевод строки + восемь пробелов» ниже не изменилась.
NEEDLE = ('\n        staging = target.with_name(target.name + f".staging.{os.getpid()}")\n'
          '        download_binary(version, staging)\n')
if t.count(NEEDLE) != 1:
    # Код 2: якорь уехал -- контроль НЕ ИЗМЕРЯЛ. sys.exit со строкой отдал бы
    # 1, то есть «случай разошёлся» (раунд 19, A-9).
    sys.stderr.write('МУТАЦИЯ НЕ ПРИМЕНИЛАСЬ: якорь ветки --update найден %d раз\n'
                     % t.count(NEEDLE))
    sys.exit(2)
t2 = t.replace(NEEDLE, '\n        staging = target\n        download_binary(version, staging)\n', 1)
if t2.count('.with_name(target.name + f".staging.{os.getpid()}")') != 1:
    sys.stderr.write('МУТАЦИЯ ЗАДЕЛА ЧУЖУЮ ВЕТКУ: стадий осталось %d\n'
                     % t2.count('.with_name(target.name + f".staging.{os.getpid()}")'))
    sys.exit(2)
open(p, 'w', encoding='utf-8').write(t2)
MUT
  __mrc=$?
  if [[ $__mrc -ne 0 ]]; then
    # Класс ответа называется: 2 -- якорь уехал и контроль НЕ ИЗМЕРЯЛ (чинить
    # прибор), прочее -- контроль не применился по иной причине.
    if [[ $__mrc -eq 2 ]]; then
      echo "  ОТКАЗ: контроль случая (u) НЕ ИЗМЕРЯЛ -- якорь мутации уехал" >&2
      __DONE=1; exit 2
    fi
    bad 'case (u) control: the mutation did not apply -- it proves nothing'
    return
  fi
  # Круг 28, F-14: жертва обязана РАЗБИРАТЬСЯ после подмены. .py-жертва
  # проверяется py_compile; провал -- код 2, а не «контроль не покраснел»:
  # покраснение разбором ничего не доказывает.
  victim_parses "$mut/claude_patch.py" || {
    echo "  ОТКАЗ: контроль случая (u) НЕ ИЗМЕРЯЛ -- замена сломала разбор жертвы ($mut/claude_patch.py)" >&2
    __DONE=1; exit 2
  }
  out="$(python3 "$ROOT/update-probe.py" "$mut" 2>&1)"; rc=$?
  # Требуется НАЗВАННАЯ причина: упавший прибор (нет соседнего файла, опечатка
  # в мутации) тоже даёт ненулевой код, и без имени причины беззубость
  # неотличима от исправности.
  if [[ $rc -ne 0 && "$out" == *"ЖИВОЙ ФАЙЛ ПЕРЕПИСАН"* ]]; then
    ok "the control reddens it by its own cause: $(printf '%s' "$out" | grep -m1 'ЖИВОЙ ФАЙЛ')"
  elif [[ $rc -ne 0 ]]; then
    bad "the control reddened by a FOREIGN cause: $(printf '%s' "$out" | grep -m1 'ПРОВАЛ\|ERROR')"
  else
    bad 'the control did NOT redden: case (u) is not testing the staging'
  fi
}

case_r() {   # возврат заимствованного файла: обе стороны и уборка полуфайла
  # Сборок нет: зуб бьёт по ТОЙ ЖЕ функции, которой cleanup возвращает живое
  # состояние tweakcc. Половина «невозможный возврат» и есть та ветка, которая
  # до волны 22 печатала WARNING и выходила нулём.
  local d rc
  echo "case r: the restore of a borrowed file answers by result and leaves no debris"
  d="$ROOT/restore"; rm -rf "$d"; mkdir -p "$d/writable" "$d/locked"
  printf 'snapshot\n' > "$d/snap"
  printf 'changed\n'  > "$d/writable/live"

  if restore_one "$d/snap" "$d/writable/live" >/dev/null 2>&1 \
     && cmp -s "$d/snap" "$d/writable/live" \
     && [[ ! -e "$d/writable/live.probe-restore" ]]; then
    ok 'a diverged live file is restored from the snapshot, and no partial file is left'
  else
    bad "restore_one did not restore the live file: $(ls -1 "$d/writable" | tr '\n' ' ')"
  fi

  # Каталог только для чтения -- возврат физически невозможен. Под root chmod
  # не остановил бы запись, и зуб бы молча выродился; такой прогон отвергается.
  printf 'changed\n' > "$d/locked/live"
  chmod 500 "$d/locked"
  restore_one "$d/snap" "$d/locked/live" >/dev/null 2>&1; rc=$?
  chmod 700 "$d/locked"
  if [[ "$(id -u)" == "0" ]]; then
    bad 'case (r) cannot measure as root: a read-only directory does not stop writes'
  elif (( rc != 0 )) && [[ ! -e "$d/locked/live.probe-restore" ]]; then
    ok 'an impossible restore answers non-zero and leaves no partial file'
  else
    bad "an impossible restore answered rc=$rc, debris: $(ls -1 "$d/locked" | tr '\n' ' ')"
  fi

  # Сборка ответа в cleanup исполняется только на выходе САМОГО зонда, поэтому
  # пинится ПО ФОРМЕ -- и это объявляется: зуб проверяет текст исполняющегося
  # файла, а не поведение.
  local self miss=()
  self="$HERE/tools/build-path-probe.sh"
  grep -qF 'restore_one "$CFG_SNAP" "$TWEAKCC_CFG" || __RESTORE_FAILED=1' "$self"       || miss+=('возврат конфига не учитывается')
  grep -qF 'restore_one "$BACKUP_SNAP" "$TWEAKCC_BACKUP" || __RESTORE_FAILED=1' "$self" || miss+=('возврат бэкапа не учитывается')
  grep -qF 'if (( __RESTORE_FAILED )); then' "$self"                                    || miss+=('провал возврата ничего не решает')
  grep -qF '    KEEP_ROOT=1' "$self"                                                    || miss+=('снимки не сохраняются')
  grep -qF '    (( __rc == 0 )) && __rc=1' "$self"                                      || miss+=('код возврата не краснеет')
  if (( ${#miss[@]} == 0 )); then
    ok 'the FORM of the aggregation holds: a failed restore keeps the snapshots and reddens the run'
  else
    bad "the aggregation form drifted: ${miss[*]}"
  fi
}

case_x() {   # двери командной строки: КЛАСС ответа и ПОРЯДОК относительно замка
  # Ни одной сборки: все три двери отвечают на разборе аргументов. Стоит это
  # миллисекунды, а закрывает то, чего не видит ни одна из проверок по образу --
  # сам разговор конвейера с вызывающим.
  local priv holder out rc mut
  echo "case x: the CLI doors answer by class, and they answer BEFORE the lock"
  priv="$ROOT/cli.lock"; : > "$priv"
  # Держатель замка -- perl с flock(2) на СВОЁМ дескрипторе: замок живёт, пока
  # жив процесс, и снимается его смертью.
  # `9>&-`: держатель переживает зонд на ~119 c, а с унаследованным
  # дескриптором он всё это время держал бы БОЕВОЙ замок конвейера -- тот же
  # отставший держатель, которого не допустит run_cli ниже.
  perl -e 'use Fcntl ":flock";
           open(my $fh, "<", $ARGV[0]) or exit 3;
           flock($fh, LOCK_EX) or exit 3;
           sleep 120;' "$priv" 9>&- &
  holder=$!
  # Глобально: cleanup обязан снять держателя на НЕштатных выходах -- штатные
  # ветки ниже снимают его сами, но только свои.
  __CLI_HOLDER=$holder
  sleep 1

  # `9>&-` и снятие CLAUDE_PATCH_LOCK_HELD_BY: ребёнок обязан идти к замку САМ,
  # иначе он унаследует замок зонда и занятой двери не увидит.
  run_cli() {   # <скрипт> <аргумент...>
    env -u CLAUDE_PATCH_LOCK_HELD_BY CLAUDE_PATCH_LOCK="$priv" bash "$@" 9>&- 2>&1
  }

  out=$(run_cli "$PIPELINE" --nonsense); rc=$?
  if [[ $rc -eq 2 && "$out" == *"unknown option"* ]]; then
    ok 'an unknown option is a broken contract (2) even while the lock is held'
  else
    bad "unknown option under a held lock answered rc=$rc: $(printf '%s' "$out" | head -1)"
  fi

  out=$(run_cli "$PIPELINE" --help); rc=$?
  if [[ $rc -eq 0 && "$out" == *"One command for the whole stack"* ]]; then
    ok '--help prints usage while the lock is held'
  else
    bad "--help under a held lock answered rc=$rc: $(printf '%s' "$out" | head -1)"
  fi

  out=$(run_cli "$PIPELINE" --target /nope --update 2.1.250); rc=$?
  if [[ $rc -eq 2 && "$out" == *"mutually exclusive"* ]]; then
    ok 'two modes at once is a broken contract (2), not a refusal on the merits'
  else
    bad "--target with --update answered rc=$rc: $(printf '%s' "$out" | head -1)"
  fi

  # Отрицательный контроль: копия конвейера, у которой разбор аргументов
  # возвращён ПОД замок. Утверждение выше обязано покраснеть на ней -- иначе оно
  # не о порядке, а о самом наличии двери.
  mut="$ROOT/cli-mutant.sh"
  if ! python3 - "$PIPELINE" "$mut" <<'MUTX'; then
import re, sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src, encoding='utf-8').read()
m = re.search(r'\nCONFIGURE=0\nONLY_OURS=0\n.*?mutually exclusive[^\n]*\n\n', t, re.S)
trap = "trap '__release_lock' EXIT\n"
if not m or t.count(trap) != 1:
    # Класс 2: мутировать нечего -- контроль НЕ ИЗМЕРЯЛ.
    sys.stderr.write('МУТАЦИЯ НЕ ПРИМЕНИЛАСЬ: блок разбора %s, трап %d раз\n'
                     % ('найден' if m else 'НЕ найден', t.count(trap)))
    sys.exit(2)
block = m.group(0)
t = t.replace(block, '\n', 1).replace(trap, trap + block.lstrip('\n'), 1)
open(dst, 'w', encoding='utf-8').write(t)
MUTX
    __xrc=$?
    if [[ $__xrc -eq 2 ]]; then
      echo "  ОТКАЗ: контроль случая (x) НЕ ИЗМЕРЯЛ -- якорь мутации уехал" >&2
      kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
      __DONE=1; exit 2
    fi
    bad 'case (x) control: the mutation did not apply -- it proves nothing'
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    return
  fi
  # Круг 28, F-14: та же проверка разбора, что у случая (u), но жертва --
  # .sh-копия конвейера: bash -n плюс разбор питоньих heredoc-тел (bash -n
  # считает heredoc данными). Держатель снимается и на этой двери отказа.
  victim_parses "$mut" || {
    echo "  ОТКАЗ: контроль случая (x) НЕ ИЗМЕРЯЛ -- замена сломала разбор жертвы ($mut)" >&2
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    __DONE=1; exit 2
  }
  out=$(run_cli "$mut" --nonsense); rc=$?
  if [[ $rc -eq 2 ]]; then
    bad 'the control did NOT redden: case (x) is not testing the ORDER'
  elif [[ $rc -eq 3 ]]; then
    ok 'the control reddens it by its own cause: parsing under the lock answers 3'
  else
    bad "the control reddened by a FOREIGN cause (rc=$rc): $(printf '%s' "$out" | head -1)"
  fi

  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  __CLI_HOLDER=''
}

case_p() {   # --target на НЕ пристинных байтах: отказ ДО того, как их трогают
  # Материал настоящий: $PATCHED -- образ, который несёт наши патчи (иначе зонд
  # не дошёл бы сюда, см. блок material). Подделывать вход не нужно и нельзя.
  local d log rc before after kit changed logm rcm f
  echo "case p: a --target run refuses non-pristine bytes before anything touches them"
  d="$(stage_dir p)"; log="$ROOT/p.log"
  cp -p "$PATCHED" "$d/claude"
  before="$(shasum -a 256 "$d/claude" | awk '{print $1}')"
  run_pipeline "$PIPELINE" "$d" "$log" --target "$d/claude"; rc=$?
  after="$(shasum -a 256 "$d/claude" | awk '{print $1}')"

  [[ $rc -eq 4 ]] \
    && ok 'refused with code 4: the bytes are not the kind the flag names' \
    || bad "answered rc=$rc instead of 4 (see $log)"
  grep -q 'already carries' "$log" \
    && ok 'the refusal names its cause' \
    || bad "the refusal does not name its cause: $(tail -1 "$log")"
  if [[ -n "$before" && "$before" == "$after" ]]; then
    ok 'the named target is byte-for-byte untouched'
  else
    bad "the target changed under a refusing run (${before:-нечитаем} -> ${after:-нечитаем})"
  fi
  # Порядок и есть предмет: отказ обязан прийти РАНЬШЕ распаковщика и стадии
  # tweakcc. Именно эта стадия 2026-08-28 переписала живую установку, а прогон
  # при этом доложил отказ -- «отказано» и «цела» перестали быть одним и тем же.
  if grep -q '^Unpacker:' "$log" || grep -q 'Applying tweakcc' "$log"; then
    bad 'the refusal came only AFTER tweakcc had been reached'
  else
    ok 'nothing was unpacked or applied before the refusal'
  fi
  # Вторая половина стража -- образ, несущий ТОЛЬКО стадию tweakcc, -- на машине
  # без сборки не материализуется, поэтому пинится ПО ФОРМЕ, и это объявляется:
  # проверяется текст конвейера, а не его поведение.
  grep -qF "elif LC_ALL=C grep -q -a -F 'tweakcc' \"\$BIN\"; then" "$PIPELINE" \
    && ok 'the tweakcc-only half of the guard is there (pinned by FORM, not run)' \
    || bad 'the tweakcc-only half of the guard is gone'

  # --- контроль: тот же прогон по копии конвейера без стража ------------------
  # Мутация одна и считается: триггер стража -> `if false`. Чтобы контроль стоил
  # секунды, а не сборку, в копии кита ПЕРВЫЙ гейт после места стража подменён
  # заглушкой: её код и её строка в логе означают ровно «прогон ДОШЁЛ сюда
  # вместо отказа кодом 4». Это объявленная граница контроля, а не измерение
  # гейта разбора.
  kit="$ROOT/kit-p"; rm -rf "$kit"; mkdir -p "$kit/tools"
  for f in "$HERE"/* "$HERE"/.[!.]*; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == tools ]] && continue
    ln -sfn "$f" "$kit/$(basename "$f")"
  done
  for f in "$HERE"/tools/*; do ln -sfn "$f" "$kit/tools/$(basename "$f")"; done
  rm -f "$kit/claude-patch-all.sh" "$kit/tools/emit-check.js"
  cat > "$kit/tools/emit-check.js" <<'STUB'
// Заглушка КОНТРОЛЯ случая (p) зонда пути сборки: первый гейт после места
// стража пристинности. Ничего не измеряет -- ограничивает прогон мутанта
// секундами и оставляет в логе строку, по которой видно, что прогон дошёл
// сюда, а не отказал кодом 4 выше.
console.error('ЗОНД-ЗАГЛУШКА: прогон дошёл до первого гейта после места стража');
process.exit(1);
STUB
  sed -E 's/^if \[\[ -n "\$TARGET" && \$ONLY_OURS -eq 0 \]\]; then$/if false; then/' \
    "$PIPELINE" > "$kit/claude-patch-all.sh"
  changed=$(diff "$PIPELINE" "$kit/claude-patch-all.sh" | grep -c '^< ' || true)
  case "$changed" in ''|*[!0-9]*) changed=0 ;; esac
  if [[ "$changed" -ne 1 ]]; then
    echo "  ОТКАЗ: контроль случая (p) НЕ ИЗМЕРЯЛ -- мутация тронула $changed строк вместо 1" >&2
    __DONE=1; exit 2
  fi

  d="$(stage_dir p-control)"; logm="$ROOT/p-control.log"
  cp -p "$PATCHED" "$d/claude"
  run_pipeline "$kit/claude-patch-all.sh" "$d" "$logm" --target "$d/claude"; rcm=$?
  if [[ $rcm -eq 4 ]]; then
    bad 'the control did NOT redden: the 4 does not come from the guard'
  elif grep -q 'ЗОНД-ЗАГЛУШКА' "$logm"; then
    ok 'the control reddens it by its own cause: without the guard the run walks past the site'
  else
    bad "the control reddened by a FOREIGN cause (rc=$rcm): $(tail -1 "$logm")"
  fi
}

echo "build-path-probe: во ВСЕХ случаях сборки sync цен пропущен (CLAUDE_PATCH_SKIP_MODELS=1)"
if __envon KEEP_ROOT; then
  echo "build-path-probe: KEEP_ROOT=${KEEP_ROOT} -- рабочий корень $ROOT останется на диске"
fi
for c in $(echo "$CASES" | grep -o .); do
  case "$c" in
    a) case_a ;;
    b) case_b ;;
    c) case_c ;;
    d) case_d ;;
    u) case_u ;;
    r) case_r ;;
    x) case_x ;;
    p) case_p ;;
    *) echo "unknown case: $c" >&2; exit 2 ;;
  esac
done

__DONE=1   # все названные случаи исполнены; ниже только вердикт
if [[ $FAILED -eq 0 ]]; then
  # Фраза про зубы принадлежит контролю, а не набору: случаи (c), (d), (u) и
  # (x) -- мутационные контроли, и без них зелёная строка обещала бы
  # доказательство, которого прогон не получал (раунд 18, H-2).
  if [[ "$CASES" == *c* || "$CASES" == *d* || "$CASES" == *u* || "$CASES" == *x* || "$CASES" == *r* || "$CASES" == *p* ]]; then
    echo "build path ($ALL_CASES): every assertion held, and the control shows they have teeth"
  else
    echo "build path ($ALL_CASES): every assertion held; НИ ОДИН контроль (c/d/u/x/r/p/l) не гонялся -- зубы не доказаны"
  fi
else
  echo "build path: $FAILED assertion(s) failed; logs under $ROOT (kept)" >&2
  KEEP_ROOT=1
  echo "build-path-probe: KEEP_ROOT=1 -- корень $ROOT оставлен для разбора" >&2
  exit 1
fi
