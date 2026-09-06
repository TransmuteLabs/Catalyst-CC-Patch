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
#   k  another probe owns the probe-only ccVersion now, or SIGKILL left it behind
#      -> must refuse before snapshotting or writing anything. Its control removes
#      that startup guard and must let the same toy HOME reach a fast case.
#   m  the two-sided reconciliation of DECLARED tweakcc misses against what
#      actually happened. The blind knob (CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES)
#      switches off the whole layer at once, and both the sweep and this probe
#      scrub it on purpose -- so a single upstream-rewritten edit used to leave
#      the kit with no way to say "this one, on this version" without going
#      blind everywhere. The case drives the pipeline's own function over toy
#      files: a declared miss passes with a NOTE, an undeclared one refuses, a
#      declared miss that did NOT happen refuses too (a row must not outlive its
#      cause), a row declared for a NEIGHBOURING version does not cover this one,
#      and an image with no version marker refuses rather than silently matching
#      nothing. Its controls disable each of those guards in turn.
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
#      lock preamble moved, the backup guard's carve anchor is gone, or the
#      canonical probe-config marker cannot be extracted. All of these
#      say "there is nothing to measure yet", not "the kit is broken" --
#      different repairs, so they must not share a code
#   3  the pipeline lock is held by another live run -- retry later
#   4  a declared number does not match the actual one: the scenario or mutation
#      table of a self-checking case was edited without moving its counter. The
#      kit's shared meaning of 4 -- "the bytes are not the ones that were named"
#      -- read for a table instead of an image
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
# Usage:  bash tools/build-path-probe.sh [--case abcdurxplkmn] [--version 2.1.247]
# Cost:   one full run per BUILD case (tweakcc + our patches + the pipeline's 119
#         checks + the interface gate + the bench), so a few minutes each; cases
#         (r), (x), (l), (k), (m) and (n) build nothing and answer in
#         milliseconds.

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
CASES=abcdurxplkmn
# Owner totals across the self-checking cases. Раньше эти два числа стояли
# ГОЛЫМИ объявлениями: их читал только гейт чисел в прозе, а сам прибор их не
# сверял ни с чем -- правка таблицы случая без правки числа проходила молча,
# то есть счётчик владельца сам был незагейчен (ровно тот класс, который кит
# чинит у соседей). Теперь у каждого случая свой вклад, EXPECTED_* обязаны быть
# их СУММОЙ, а длина таблицы сверяется со вкладом ВНУТРИ случая: K -- по
# построению (один сценарий, одна мутация), L и M -- длиной своих списков.
CASE_K_SCENARIOS=1; CASE_K_MUTATIONS=1
CASE_L_SCENARIOS=4; CASE_L_MUTATIONS=4
CASE_M_SCENARIOS=9; CASE_M_MUTATIONS=11
CASE_N_SCENARIOS=77; CASE_N_MUTATIONS=84
EXPECTED_SCENARIOS=91
EXPECTED_MUTATIONS=100
if (( EXPECTED_SCENARIOS != CASE_K_SCENARIOS + CASE_L_SCENARIOS + CASE_M_SCENARIOS + CASE_N_SCENARIOS
      || EXPECTED_MUTATIONS != CASE_K_MUTATIONS + CASE_L_MUTATIONS + CASE_M_MUTATIONS + CASE_N_MUTATIONS )); then
  echo "build-path-probe: ОТКАЗ -- объявленная сумма разошлась со вкладами случаев:" >&2
  echo "  сценариев $EXPECTED_SCENARIOS против $((CASE_K_SCENARIOS + CASE_L_SCENARIOS + CASE_M_SCENARIOS + CASE_N_SCENARIOS))," \
       "мутаций $EXPECTED_MUTATIONS против $((CASE_K_MUTATIONS + CASE_L_MUTATIONS + CASE_M_MUTATIONS + CASE_N_MUTATIONS))" >&2
  exit 4
fi
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

# Значение принадлежит конвейеру: дубль здесь сделал бы случай (k) зелёным по
# маркеру, которого исполняющийся конвейер уже не использует.
TWEAKCC_PROBE_CFG_MARKER="$(sed -n "s/^TWEAKCC_PROBE_CFG_MARKER='\\(.*\\)'$/\\1/p" "$PIPELINE")"
if [[ -z "$TWEAKCC_PROBE_CFG_MARKER" ]]; then
  echo "build-path-probe: ОТКАЗ -- не найден непустой TWEAKCC_PROBE_CFG_MARKER в $PIPELINE" >&2
  echo "  Прибор не знает, какое ccVersion является следом оборванного зонда." >&2
  exit 2
fi

case_k() {   # чужой probe-marker: отказ до снимка, игрушечный HOME
  local d home cfg before after out rc self kit mut mout mrc ver patched pristine f discrepancies=0
  d="$(mktemp -d "${TMPDIR:-/tmp}/cc-build-path-probe-k.XXXXXX")"
  home="$d/home"; cfg="$home/.tweakcc/config.json"
  ver=9.9.9
  patched="$home/.local/share/claude/versions/$ver"
  pristine="$patched.orig"
  mkdir -p "$(dirname "$cfg")" "$(dirname "$patched")" "$d/tmp" "$d/kit/tools"
  printf '{"ccVersion":"%s","kept":"byte-for-byte"}\n' "$TWEAKCC_PROBE_CFG_MARKER" > "$cfg"
  printf 'prefix %s suffix\n' "$OUR_MARKER" > "$patched"
  printf 'pristine toy bytes\n' > "$pristine"
  before="$(shasum -a 256 "$cfg" | awk '{print $1}')"
  self="$HERE/tools/build-path-probe.sh"

  out="$(HOME="$home" TMPDIR="$d/tmp" bash "$self" --case r --version "$ver" 2>&1)"; rc=$?
  after="$(shasum -a 256 "$cfg" | awk '{print $1}')"
  if [[ $rc -ne 2 || "$out" != *"ccVersion is the build-path probe marker"* \
        || "$out" != *"has two possible meanings"* \
        || "$out" != *"SIGKILL does not run the probe's trap"* \
        || "$out" != *"another build-path probe may be running now"* \
        || "$out" != *"wait for it to finish"* ]]; then
    echo "  FAIL   K: marker config answered rc=$rc without the startup guard's own reason" >&2
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    rm -rf "$d"
    return 1
  fi
  if [[ -z "$before" || "$before" != "$after" ]]; then
    echo "  FAIL   K: the refusing probe changed the toy config ($before -> $after)" >&2
    rm -rf "$d"
    return 1
  fi
  echo "  ok     K: marker config is refused with code 2 before the file changes"

  # Контроль исполняет тот же вход по копии зонда без одной ветки стража. Он
  # обязан потерять ИМЕННО текст отказа; код ребёнка не используется как зуб,
  # потому что случай (r) после снятого стража может упасть по соседней причине.
  cp -p "$self" "$d/kit/tools/build-path-probe.sh"
  ln -s "$PIPELINE" "$d/kit/claude-patch-all.sh"
  for f in "$HERE"/tools/*; do
    [[ "$(basename "$f")" == build-path-probe.sh ]] && continue
    ln -s "$f" "$d/kit/tools/$(basename "$f")"
  done
  mut="$d/kit/tools/build-path-probe.sh"
  python3 - "$mut" <<'PY_K_MUT'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
a = '# --- killed-predecessor config guard ----------------------------------------\n'
b = '# --- end killed-predecessor config guard ------------------------------------\n'
if s.count(a) != 1 or s.count(b) != 1 or s.index(a) >= s.index(b):
    sys.stderr.write('МУТАЦИЯ НЕ ПРИМЕНИЛАСЬ: ветка startup guard не найдена ровно один раз\n')
    raise SystemExit(2)
s = s[:s.index(a)] + s[s.index(b) + len(b):]
p.write_text(s, encoding='utf-8')
PY_K_MUT
  mrc=$?
  if [[ $mrc -ne 0 ]]; then
    rm -rf "$d"
    [[ $mrc -eq 2 ]] && return 2
    return 1
  fi
  mout="$(HOME="$home" TMPDIR="$d/tmp" bash "$mut" --case r --version "$ver" 2>&1)"; mrc=$?
  after="$(shasum -a 256 "$cfg" | awk '{print $1}')"
  if [[ "$mout" != *"ccVersion is the build-path probe marker"* \
        && -n "$before" && "$before" == "$after" ]]; then
    echo "  RED    K mutation: removing the startup guard removes its own refusal text (child rc=$mrc)"
  else
    echo "  FAIL   K mutation kept the guard text or changed the toy config (rc=$mrc)" >&2
    printf '%s\n' "$mout" | sed 's/^/        /' >&2
    rm -rf "$d"
    return 1
  fi
  rm -rf "$d"
  echo "build-path-probe K: case held and its control showed teeth"
}

if [[ "$CASES" == *k* ]]; then
  case_k || exit $?
  CASES="${CASES//k/}"
  if [[ -z "$CASES" ]]; then
    echo "build path ($ALL_CASES): every assertion held, and the control shows they have teeth"
    exit 0
  fi
fi

case_l() {
  python3 - "$PIPELINE" "$CASE_L_SCENARIOS" "$CASE_L_MUTATIONS" <<'PY_LSOF'
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
                              capture_output=True, text=True, errors="replace")

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
if len(checks) != int(sys.argv[2]) or len(mutations) != int(sys.argv[3]):
    print("  FAIL   L: таблица разошлась с объявленным вкладом -- сценариев %d/%s, мутаций %d/%s"
          % (len(checks), sys.argv[2], len(mutations), sys.argv[3]))
    raise SystemExit(4)

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

print("build-path-probe L: case held and its controls showed teeth")
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

# Сверка объявленных непроходов tweakcc. Гоняется САМА функция конвейера над
# игрушечными файлами: слепая ручка на весь слой (CLAUDE_PATCH_ALLOW_TWEAKCC_
# FAILURES) вычищается и свипом, и этим зондом намеренно, поэтому единственный
# способ сказать «эта правка на этой версии» -- запись, а у записи обязаны быть
# ОБЕ стороны: она пропускает объявленное и не даёт пережить свою причину.
case_m() {
  python3 - "$PIPELINE" "$CASE_M_SCENARIOS" "$CASE_M_MUTATIONS" "$HERE/tools/tw-layer.sh" "${BASH_SOURCE[0]}" <<'PY_MISSES'
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
declared_s, declared_m = int(sys.argv[2]), int(sys.argv[3])
# Сверка непроходов разбирает вывод НЕ своей копией разбора, а общим носителем
# (__tw_layer_names), и слой у неё -- код. Поэтому в оснастку едут трое: сам
# носитель, перечисления секций (без них он под `set -u` не запустится) и
# функция сверки. Извлечение объявляет каждого: пропажа любого -- «прибор не
# может мерить», а не тихо усечённый механизм.
sections = re.findall(r"(?m)^__TW_(?:CODE|PROMPT)_SECTIONS=.*\n", source)
carrier = re.search(r"(?ms)^__tw_layer_names\(\) \{\n.*?^\}\n", source)
match = re.search(r"(?ms)^__tw_reconcile_misses\(\) \{\n.*?^\}\n", source)
# Предбанник якоря едет СЮДА же: он стоит в конвейере ПЕРЕД сверкой непроходов,
# и оснастка без него мерила бы порядок дверей, которого у конвейера нет.
vestibule = re.search(r"(?ms)^__tw_check_anchor\(\) \{.*?^\}\n", source)
# Носитель разбора -- ОБЁРТКА над общим домом (tools/tw-layer.sh): сам разбор
# живёт там, и оснастка без него звала бы неопределённую функцию, то есть мерила
# бы собственную усечённость вместо механизма.
layer = Path(sys.argv[4]).read_text(encoding="utf-8")
layer_consts = re.findall(r"(?m)^(?:TW_MARKS|__TW_LINE_RE|TW_RESULTS_ANCHOR)=.*\n", layer)
layer_fns = [m.group(0) for m in
             re.finditer(r"(?ms)^(?:tw_layer_names|tw_unsectioned_lines"
                         r"|tw_results_anchor_count)\(\) \{.*?^\}\n", layer)]
if (len(sections) != 2 or not carrier or not match or not vestibule
        or len(layer_consts) != 3 or len(layer_fns) != 3):
    print("  FAIL   M: механизм сверки непроходов не извлечён (присваиваний секций %d, "
          "нужно 2; носитель разбора %s; сверка %s; предбанник якоря %s; констант "
          "разбора %d, нужно 3, и функций разбора %d, нужно 3)"
          % (len(sections), bool(carrier), bool(match), bool(vestibule),
             len(layer_consts), len(layer_fns)))
    raise SystemExit(2)
function = ("".join(sections) + "".join(layer_consts) + "".join(layer_fns)
            + carrier.group(0) + vestibule.group(0) + match.group(0))

# Проверка ПРИЧИН покраснения берётся из ЕДИНСТВЕННОГО дома -- случая (n)
# ниже по этому же файлу, между метками CAUSE-HOME. Вторая редакция этих
# двенадцати строк разошлась бы с первой на первой же правке и разошлась бы
# МОЛЧА: сломанная проверка причин выглядит ровно как проверка, которая прошла.
# Путь берётся из BASH_SOURCE, а не из имени: в снимке кита корпусного стенда
# зонд лежит под другим именем, и пин по имени вырезал бы из чужого файла.
# Блоков обязан быть РОВНО один: ноль -- метки уехали, два -- дом раздвоился, и
# обе поломки тихие.
probe_src = Path(sys.argv[5]).read_text(encoding="utf-8")
cause_home = re.findall(r"(?ms)^# CAUSE-HOME-BEGIN\n(.*?)^# CAUSE-HOME-END\n", probe_src)
if len(cause_home) != 1:
    print("  FAIL   M: дом проверки причин не вырезан из %s (блоков %d, нужно 1)"
          % (sys.argv[5], len(cause_home)))
    raise SystemExit(2)
exec(cause_home[0], globals())

VER = "2.1.257"
NEIGHBOUR = "2.1.252"
MISS = "Clear screen command"
CODE_SECTION = "Always Applied"


def sec(title, lines):
    """Секция вывода форка: пустая строка, заголовок с двумя пробелами, строки
    правок с четырьмя. Слой опознаётся ИМЕННО секцией, поэтому голый список
    строк, каким оснастка обходилась прежде, больше ничего не измеряет."""
    return "\n  %s:\n" % title + "".join("    %s\n" % ln for ln in lines)


def run(body, misses, out_text, marker=VER, blind=False):
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        mf = root / "misses.txt"
        mf.write_text(misses, encoding="utf-8")
        of = root / "tweakcc.out"
        of.write_text(out_text, encoding="utf-8")
        img = root / "image"
        # Байты с NUL: версия читается из ОБРАЗА, а grep без LC_ALL=C на таком
        # файле молчит -- это и есть измеряемое поведение, не декорация.
        marker_bytes = ("// Version: %s\n" % marker).encode() if marker else b"no version marker\n"
        img.write_bytes(b"\x00\x01binary\x00noise\x00" + marker_bytes + b"\x00tail\x00")
        env = "CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1\n" if blind else ""
        script = ("set -uo pipefail\n" + env
                  + "TWEAKCC_KNOWN_MISSES=%s\n" % shlex.quote(str(mf))
                  + body
                  # Порядок конвейерный: предбанник якоря ПЕРВЫМ, сверка второй.
                  # Область чтения задаёт якорь, и сверка, посчитавшая ✗ по
                  # пустой области, объявляет чистой любую версию.
                  + "\n__tw_check_anchor %s || exit $?\n" % shlex.quote(str(of))
                  + "__tw_reconcile_misses %s %s\n" % (shlex.quote(str(of)), shlex.quote(str(img))))
        return subprocess.run(["bash"], input=script, capture_output=True, text=True, errors="replace")


# Якорь блока результатов: читатели кита ограничены областью ПОСЛЕ него, и
# вывод без якоря мерил бы пустоту -- сверка непроходов не увидела бы ни одной
# строки, а сценарий доказывал бы не тот вход.
ANCHOR = "Patches applied (run with --show-unchanged to show all patches):"
out_miss = "patch: 13 applied, 1 failed\n" + ANCHOR + "\n" + sec(
    CODE_SECTION, ["✗ %s — upstream description" % MISS])
out_clean = ("patch: 14 applied, 0 failed\n" + ANCHOR + "\n"
             + sec(CODE_SECTION, ["✓ patch 0 — ok"]))
row_here = "%s\t%s\tапстрим переписал участок\n" % (VER, MISS)
row_neighbour = "%s\t%s\tчужая версия\n" % (NEIGHBOUR, MISS)

# Вывод БЕЗ ЯКОРЯ: форк сменил строку, открывающую блок результатов. Область
# чтения тогда пуста, крестиков не видно, и сверка непроходов объявила бы
# версию чистой, а объявленный непроход -- «не случившимся».
out_no_anchor = "patch: 13 applied, 1 failed\n" + sec(
    CODE_SECTION, ["✗ %s — upstream description" % MISS])

SCEN = {
    "M1": (row_here, out_miss, VER, False,
           lambda r: r.returncode == 0 and "NOTE:" in r.stderr and MISS in r.stderr),
    "M2": ("", out_miss, VER, False,
           lambda r: r.returncode == 1 and ("НЕ объявлена для %s" % VER) in r.stderr),
    "M3": (row_here, out_clean, VER, False,
           lambda r: r.returncode == 1 and "НЕ СЛУЧИЛОСЬ" in r.stderr),
    "M4": (row_neighbour, out_miss, VER, False,
           lambda r: r.returncode == 1 and ("НЕ объявлена для %s" % VER) in r.stderr),
    "M5": ("", out_clean, None, False,
           lambda r: r.returncode == 1 and "не может назвать версию" in r.stderr),
    "M6": ("", out_clean, VER, False,
           lambda r: r.returncode == 0 and "NOTE:" not in r.stderr and "FATAL" not in r.stderr),
    # BOM первой строки объявления: `[[:space:]]` его не берёт, и файл,
    # сохранённый редактором с меткой порядка байтов, терял бы первую строку --
    # объявленный непроход читался бы как необъявленный, и сборка отказывала бы
    # по чужой причине. Приём тот же, что у всех прочих читателей объявлений.
    "M7": ("\ufeff" + row_here, out_miss, VER, False,
           lambda r: r.returncode == 0 and "NOTE:" in r.stderr and MISS in r.stderr),
    # ПОРЯДОК ДВЕРЕЙ. Якорь сменился, а строка непрохода на эту версию есть:
    # первой обязана сказать дверь ЯКОРЯ. Прежде якорь проверялся внутри двери
    # уровня, то есть ПОСЛЕ сверки, и оператора посылали снять ДЕЙСТВУЮЩЕЕ
    # объявление -- следствие впереди причины.
    "M8": (row_here, out_no_anchor, VER, False,
           lambda r: r.returncode == 1
                     and "якорь блока результатов tweakcc встречается 0 раз" in r.stderr
                     and "НЕ СЛУЧИЛОСЬ" not in r.stderr),
    # Слепая ручка ГАСИТ сверку, а не отменяет её. Вход: ручка=1, крестиков нет,
    # объявленный непроход НЕ случился. Прежде вызов стоял только на ветке с
    # выключенной ручкой, и здесь не печаталось ничего.
    "M9": (row_here, out_clean, VER, True,
           lambda r: r.returncode == 0 and "НЕ СЛУЧИЛОСЬ" in r.stderr
                     and "FATAL" not in r.stderr
                     and "дверь сверки непроходов tweakcc погашена" in r.stderr),
}
ORDER = ["M1", "M2", "M3", "M4", "M5", "M6", "M7", "M8", "M9"]

mutations = [
    ("M1-note-dropped", 'if [[ -n "$__declared_rows" ]]; then', "if false; then", "M1"),
    ("M2-undeclared-ignored", 'if [[ -n "$__only_actual" ]]; then', "if false; then", "M2"),
    # Предмет сверки -- крестики слоя КОДА: слой промтов их не печатает вовсе,
    # и читатель, спутавший слой, нашёл бы пустое множество и молча объявил
    # версию чистой -- ровно та тишина, ради которой сверка и заведена.
    ("M2-misses-read-wrong-layer",
     '__tw_layer_names "$__out" code \'✗\'', '__tw_layer_names "$__out" prompt \'✗\'', "M2"),
    ("M3-stale-ignored", 'if [[ -n "$__only_declared" ]]; then', "if false; then", "M3"),
    ("M4-version-filter-off", "$1==v { gsub(", "1 { gsub(", "M4"),
    ("M5-version-guard-off",
     'if [[ ! "$__ver" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+ ]]; then', "if false; then", "M5"),
    ("M7-misses-bom-kept",
     'LC_ALL=C sed $\'1s/^\\xef\\xbb\\xbf//\' "$TWEAKCC_KNOWN_MISSES" \\\n    | awk',
     'LC_ALL=C cat "$TWEAKCC_KNOWN_MISSES" \\\n    | awk', "M7"),
    # Предбанник якоря СНЯТ: сверка идёт по пустой области, крестиков не видит и
    # объявляет действующее объявление «непроходом, которого не случилось» --
    # ровно то следствие впереди причины, ради снятия которого предбанник и
    # вынесен из двери уровня.
    ("M8-anchor-vestibule-off",
     'if (( __n != 1 )); then\n    echo "FATAL: якорь блока',
     'if false; then\n    echo "FATAL: якорь блока', "M8"),
    # Второй читатель того же объявления -- перечень строк для совета. Метку
    # порядка байтов снимают ОБА, и мутация у каждого своя: пропажа зуба у
    # второго читателя не видна первому.
    ("M7-declared-rows-bom-kept",
     '__declared_rows="$(LC_ALL=C sed $\'1s/^\\xef\\xbb\\xbf//\' "$TWEAKCC_KNOWN_MISSES" 2>/dev/null',
     '__declared_rows="$(LC_ALL=C cat "$TWEAKCC_KNOWN_MISSES" 2>/dev/null', "M7"),
    # Гашение сверки обязано быть ОБЪЯВЛЕННЫМ: молча снятая дверь неотличима от
    # двери, которая держится.
    ("M9-blind-extinguish-silent",
     'echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь сверки непроходов tweakcc погашена (не объявлено',
     'true "', "M9"),
    # ...и ручка обязана ГАСИТЬ, а не отказывать: со взведённой ручкой сверка
    # печатает найденное и возвращает ноль.
    ("M9-blind-still-refuses",
     '__say="NOTE"; __blind_rc=0',
     '__say="FATAL"; __blind_rc=1', "M9"),
]

# ПРИЧИНА покраснения -- по одной на мутацию, тем же приёмом и тем же кодом,
# что у случая (n): проверка живёт в одном доме и вырезана выше. Без причины
# зуб доказывает чужое правило -- сценарий краснеет и от отказа СОСЕДНЕЙ двери,
# и от упавшего прибора, и беззубость от исправности не отличить.
#
# Ключ -- ИМЯ мутации, а не позиция: параллельная таблица разъезжается на
# первой же вставке в середину, и мутация тихо получает чужую причину.
CAUSE = {
    "M1-note-dropped": "нет: NOTE: объявленные непроходы tweakcc на",
    "M2-undeclared-ignored": "нет: НЕ объявлена для %s" % VER,
    "M2-misses-read-wrong-layer": "нет: НЕ объявлена для %s" % VER,
    "M3-stale-ignored": "нет: объявлен непроход, которого НЕ СЛУЧИЛОСЬ",
    "M4-version-filter-off": "нет: НЕ объявлена для %s" % VER,
    "M5-version-guard-off": "нет: не может назвать версию образа",
    # Мутант краснеет соседней ВЕТКОЙ своей двери умышленно: непрочитанная
    # метка порядка байтов делает объявленный непроход необъявленным.
    "M7-misses-bom-kept": "НЕ объявлена для %s" % VER,
    # Метку снимают ДВА читателя одного файла, и у каждого своя мутация: у
    # значения (выше) и у перечня строк совета (здесь). Одна мутация на двоих
    # оставляла бы второго читателя без зуба -- ровно тот раскол, который у
    # файла кита уже пришлось развести на N50 и N51.
    "M7-declared-rows-bom-kept": "нет: NOTE: объявленные непроходы tweakcc на",
    # Снятый предбанник якоря пускает сверку считать ПУСТУЮ область: действующее
    # объявление читается как непроход, которого не случилось, -- следствие
    # впереди причины, ради снятия которого предбанник и вынесен из двери уровня.
    "M8-anchor-vestibule-off": ("объявлен непроход, которого НЕ СЛУЧИЛОСЬ",
                                "нет: якорь блока результатов tweakcc встречается"),
    "M9-blind-extinguish-silent": "нет: дверь сверки непроходов tweakcc погашена",
    "M9-blind-still-refuses": "FATAL: для %s объявлен непроход" % VER,
}
missing_cause = [m[0] for m in mutations if m[0] not in CAUSE]
if missing_cause:
    print("  FAIL   M: мутации без объявленной причины покраснения: %s"
          % ", ".join(missing_cause))
    raise SystemExit(4)

if len(ORDER) != declared_s or len(mutations) != declared_m:
    print("  FAIL   M: таблица разошлась с объявленным вкладом -- сценариев %d/%d, мутаций %d/%d"
          % (len(ORDER), declared_s, len(mutations), declared_m))
    raise SystemExit(4)

failed = 0
# След здорового прогона нужен объявлениям отсутствия, и берётся он ОТСЮДА:
# второй прогон того же сценария ради причины удвоил бы стенд.
base_evidence = {}
for name in ORDER:
    misses, out_text, marker, blind, predicate = SCEN[name]
    result = run(function, misses, out_text, marker, blind)
    base_evidence[name] = cause_evidence(result)
    if predicate(result):
        print("  ok     %s" % name)
    else:
        failed += 1
        print("  FAIL   %s rc=%s stderr=%r" % (name, result.returncode, result.stderr))

for mutation, old, new, owner in mutations:
    if function.count(old) != 1:
        failed += 1
        print("  FAIL   mutation %s anchor count=%s" % (mutation, function.count(old)))
        continue
    misses, out_text, marker, blind, predicate = SCEN[owner]
    result = run(function.replace(old, new, 1), misses, out_text, marker, blind)
    evidence = cause_evidence(result)
    why = cause_verdict(CAUSE[mutation], evidence, base_evidence[owner])
    if predicate(result):
        failed += 1
        print("  FAIL   mutation %s did not redden %s" % (mutation, owner))
    elif why:
        failed += 1
        print("  FAIL   mutation %s покраснила %s ЧУЖОЙ причиной: %s" % (mutation, owner, why))
        print("         объявлено: %r, было: %s"
              % (CAUSE[mutation], evidence.replace("\n", "|")[:300]))
    else:
        print("  RED    mutation %s (%s)" % (mutation, owner))

print("build-path-probe M: case held and its controls showed teeth")
raise SystemExit(1 if failed else 0)
PY_MISSES
}

# Дверь УРОВНЯ tweakcc (сколько правок легло). Предмет соседний со случаем M,
# но не тот же: M видит поимённые ✗, а проседание слоя случается ИМЕННО без
# крестиков -- когда данных под версию нет, правки не пробуются вовсе. Так
# падение 33 -> 14 прошло вердиктом «красных нет». Гоняются САМИ функции
# конвейера над игрушечными файлами.
#
# Уровень РАЗДЕЛЁН на два слоя, потому что у них разные владельцы: код
# принадлежит версии апстрима и нашему форку (дверь двусторонняя), промты --
# каталогу накладок ПОЛЬЗОВАТЕЛЯ (дверь ПОЛОМ, одностороння). Пин суммы
# измеренно неустойчив: 2.1.259 дала 34 и 33 на неизменном образе. Третий
# счёт -- накладки, которых в образе не нашлось: они печатаются НЕ крестиком,
# и сверка непроходов их не видит вовсе.
#
# У самого слоя кода владельцев тоже оказалось не два, а ТРИ: реестр форка
# (сколько правок пробуется), версия апстрима (какие не легли) и конфиг ДОМА
# tweakcc (какие выключены). Поэтому дверь уровня гейтит ПОПЫТКИ (✓+✗+○), а
# множество выключенных получило свою дверь у своего владельца -- объявление
# рядом с config.json. Случай гоняет ОБЕ двери в том же порядке, что и
# конвейер: уровень первым, множество вторым.
case_n() {
  python3 - "$PIPELINE" "$CASE_N_SCENARIOS" "$CASE_N_MUTATIONS" "$HERE/tools/tw-layer.sh" <<'PY_LEVEL'
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
declared_s, declared_m = int(sys.argv[2]), int(sys.argv[3])
# Механизм собран из ДВУХ файлов, потому что и конвейер собирает его из двух:
# разбор вывода живёт в общем доме (tools/tw-layer.sh), который конвейер
# подключает, а двери и счётчики -- в самом конвейере. Оснастка, взявшая только
# конвейер, звала бы неопределённую функцию, и КАЖДЫЙ счёт вышел бы пустым --
# то есть зонд мерил бы собственную усечённость, а не механизм.
layer = Path(sys.argv[4]).read_text(encoding="utf-8")
# Перечисления секций живут ВНЕ функций (они общие для носителя разбора и для
# часового формы), и без них ни один счётчик под `set -u` не запустится --
# поэтому они извлекаются наравне с функциями. Их РОВНО два: слой опознаётся
# секцией, и третье перечисление означало бы, что механизм разошёлся с
# оснасткой, а не что оснастка чего-то не знает.
sections = re.findall(r"(?m)^__TW_(?:CODE|PROMPT)_SECTIONS=.*\n", source)
# Из дома разбора едут его константы (набор знаков, форма строки правки и ЯКОРЬ
# блока результатов: без них awk под `set -u` не запустится) и все функции
# разбора. Якорь тут не роскошь: он задаёт ОБЛАСТЬ чтения, и оснастка без него
# мерила бы пустоту -- каждый счёт вернул бы ноль, а зелёный сценарий не
# доказывал бы ничего.
layer_consts = re.findall(r"(?m)^(?:TW_MARKS|__TW_LINE_RE|TW_RESULTS_ANCHOR)=.*\n", layer)
layer_fns = [m.group(0) for m in
             re.finditer(r"(?ms)^(?:tw_layer_names|tw_unsectioned_lines"
                         r"|tw_results_anchor_count)\(\) \{.*?^\}\n", layer)]
# Счётчики берутся ПО ОБРАЗЦУ ИМЕНИ, а не перечнем. Перечень уже был
# дефектом того же класса, что и локаторы: он назывался списком счётчиков, а
# на деле пинил ТРИ имени, и счётчик, добавленный в конвейер четвёртым,
# оставался бы за бортом извлечения -- дверь в оснастке звала бы
# несуществующую функцию, а зонд считал бы её показания настоящими. Образец
# ловит любой __tw_*-счётчик; дверь исключается по имени, потому что она
# ставится ПОСЛЕ всех счётчиков. Пол в три штуки оставлен: пустая выборка
# (образец разошёлся с конвейером) обязана краснеть, а не давать пустую
# оснастку, которая тихо проходит.
counters = [m for m in re.finditer(r"(?ms)^(__tw_[a-z0-9_]+)\(\) \{.*?^\}\n", source)
            if m.group(1) != "__tw_check_applied_level"]
door = re.search(r"(?ms)^__tw_check_applied_level\(\) \{\n.*?^\}\n", source)
if (len(sections) != 2 or not door or len(counters) < 3
        or len(layer_consts) != 3 or len(layer_fns) != 3):
    print("  FAIL   N: механизм уровня tweakcc не извлечён (присваиваний секций %d, "
          "нужно 2; счётчиков %d, нужно не меньше 3; констант разбора %d и функций "
          "разбора %d, нужно по 3)"
          % (len(sections), len(counters), len(layer_consts), len(layer_fns)))
    raise SystemExit(2)
function = ("".join(sections) + "".join(layer_consts) + "".join(layer_fns)
            + "".join(c.group(0) for c in counters) + door.group(0))

VER = "2.1.257"
NEIGHBOUR = "2.1.252"
# Секции форка: слой правки определяется ИМИ. Имя правки принадлежит оператору
# (у накладки оно взято из frontmatter его файла), поэтому в каждом выводе
# оснастки стоят ПРИМАНКИ: правка КОДА, названная как типизированная накладка,
# и накладка, не названная ни одним типом. Под прежним разбором по префиксу
# имени первая уезжала в счёт промтов, вторая -- в счёт кода, и одно
# переименование в чужом каталоге красило сборку на всех версиях. Приманки
# стоят в КАЖДОМ выводе, поэтому счёт любого сценария доказывает атрибуцию.
CODE_SECTIONS = ["Always Applied", "Misc Configurable", "Features"]
PROMPT_SECTION = "System Prompts"
CODE_DECOY = "Data: model list"
PROMPT_DECOY = "Custom Kind: my overlay"
# Якорь блока результатов. Форк печатает ДВА блока под ОДНИМИ заголовками
# секций -- предапплайный список плана и результаты, -- и читатели кита
# ограничены областью ПОСЛЕ якоря. Вывод оснастки без якоря мерил бы пустую
# область, то есть не тот вход: любой счёт вернул бы ноль, и зелёный сценарий
# ничего бы не доказывал.
ANCHOR = "Patches applied (run with --show-unchanged to show all patches):"


def sec(title, lines):
    return "\n  %s:\n" % title + "".join("    %s\n" % ln for ln in lines)


def out_rows(code, prompts=0, failed=0, notfound=0, off=0,
             extra_prompt=(), stray="", unknown=(), vskip=0, noop=0, pfail=0,
             anchors=1, plan=""):
    """Вывод форка: заголовок, промахи накладок, ЯКОРЬ, затем СЕКЦИИ правок.

    stray -- строки правок ДО первой секции (но ПОСЛЕ якоря: до якоря область
    не читается вовсе); unknown -- секция, которой нет ни в одном перечислении.
    И то и другое обязано быть отказом: строка без известной секции не
    принадлежит ни одному слою.

    plan -- текст ДО якоря: так форк печатает предапплайный список плана. Он
    обязан оставаться невидимым для всех читателей. anchors -- сколько раз
    печатается якорь; дверь требует ровно один.

    vskip -- «⊘», правка не пробовалась ПО ВЕРСИИ; noop -- «≡», пробовалась и
    не изменила ничего; pfail -- «✗» слоя НАКЛАДОК. Три исхода печатались одним
    кружком до волны 39c, и счёт кружков принадлежал сразу трём владельцам.
    """
    buckets = dict((t, []) for t in CODE_SECTIONS)

    def put(i, line):
        buckets[CODE_SECTIONS[i % len(CODE_SECTIONS)]].append(line)

    for i in range(code):
        put(i, "✓ %s — ok" % (CODE_DECOY if i == 0 else "patch %d" % i))
    for i in range(failed):
        put(i, "✗ patch f%d — upstream rewrote it" % i)
    # Выключенная конфигурацией правка печатается ОДНИМ именем -- ни тире, ни
    # описания у неё нет. Форма не косметическая: разбор имени у обеих дверей
    # срезает описание, и строка с описанием не доказала бы ничего о кружках.
    for i in range(off):
        put(i, "○ patch o%d" % i)
    for i in range(vskip):
        put(i, "⊘ patch v%d" % i)
    for i in range(noop):
        put(i, "≡ patch n%d" % i)
    prompt_lines = ["✓ %s — ok" % (PROMPT_DECOY if i == 0 else "Skill: overlay %d" % i)
                    for i in range(prompts)]
    # Крестик слоя НАКЛАДОК: форк ставит его каждой легшей накладке, когда не
    # смог записать хэши. Читателя у него не было вовсе -- полный обвал слоя
    # проходил молча.
    prompt_lines += ["✗ Skill: overlay p%d — hashes not written" % i for i in range(pfail)]
    prompt_lines += list(extra_prompt)
    text = "patch: %d applied, %d failed\n" % (code + prompts, failed)
    text += "".join('Could not find system prompt "overlay m%d" in cli.js (using regex /x/)\n' % i
                    for i in range(notfound))
    text += plan
    text += ANCHOR + "\n" if anchors >= 1 else ""
    text += stray
    text += sec(PROMPT_SECTION, prompt_lines)
    for title in CODE_SECTIONS:
        text += sec(title, buckets[title])
    for title, lines in unknown:
        text += sec(title, lines)
    # Второй якорь -- это второй прогон tweakcc, слитый в один вывод: счёта
    # сложились бы по двум сборкам сразу.
    text += (ANCHOR + "\n") * max(0, anchors - 1)
    return text


def off_body(out_text):
    """Тело объявления дома, выведенное из вывода: имена ○ слоя КОДА.

    Разбор здесь СВОЙ, а не позаимствованный у кита: оснастка, берущая имена
    той же функцией, что и дверь, согласилась бы с дверью при любой её
    поломке -- и мутация счётчика имён осталась бы зелёной.
    """
    names = set()
    cur = None
    for line in out_text.splitlines():
        head = re.match(r"^  (\S.*):$", line)
        if head:
            cur = head.group(1)
            continue
        if not line.startswith("    ○ ") or cur not in CODE_SECTIONS:
            continue
        names.add(line[len("    ○ "):].split(" — ")[0].rstrip())
    return "".join(name + "\n" for name in sorted(names))


def inert_names(out_text, sign):
    """Имена инертных правок слоя КОДА под названным знаком -- СВОИМ разбором.

    Оснастка, спросившая ту же функцию, что и дверь, согласилась бы с дверью при
    любой её поломке -- и мутация разбора осталась бы зелёной. Область здесь
    тоже считается от якоря: иначе оснастка объявляла бы имена, которых дверь
    не видит, и сценарий краснел бы по своей же неточности.
    """
    names = []
    cur = None
    seen_anchor = False
    for line in out_text.splitlines():
        if line.startswith(ANCHOR):
            seen_anchor = True
            cur = None
            continue
        if not seen_anchor:
            continue
        head = re.match(r"^  (\S.*):$", line)
        if head:
            cur = head.group(1)
            continue
        pre = "    %s " % sign
        if line.startswith(pre) and cur in CODE_SECTIONS:
            names.append(line[len(pre):].split(" — ")[0].rstrip())
    return sorted(set(names))


def inert_body(out_text, why="измерено"):
    """Сходящееся объявление инертных правок: обе стороны, оба знака."""
    rows = ""
    for sign in ("⊘", "≡"):
        for name in inert_names(out_text, sign):
            rows += "%s\t%s\t%s\t%s\n" % (VER, sign, name, why)
    return rows


# Столбец 2 файла кита объявляет ПОПЫТКИ: 14 легших плюс один непроход --
# пятнадцать. Пол слоя накладок в этом файле БОЛЬШЕ НЕ ЖИВЁТ: его владелец --
# каталог накладок оператора, и дом у него теперь в доме tweakcc машины.
row_here = "%s\t15\tизмерено\n" % VER
row_neighbour = "%s\t15\tчужая версия\n" % NEIGHBOUR
row_indented = "  %s\t15\tвписана с отступом\n" % VER
row_empty_code = "%s\t\tполе кода не заполнено\n" % VER
floor_here = "%s\t21\tизмерено\n" % VER
floor_nolayer = "%s\tнет-слоя\tапстрим под версию данных не даёт\n" % VER
floor_bad = "%s\tмного\tпол испорчен\n" % VER
# Пол без НАЗВАННОГО происхождения: пустое третье поле и оставленная дословно
# заглушка совета -- одно и то же, число без причины.
floor_nowhy = "%s\t21\t\n" % VER
floor_placeholder = "%s\t21\t<причина/происхождение числа>\n" % VER
floor_other = "%s\t21\tчужая версия\n" % NEIGHBOUR
floor_empty_field = "%s\t\tполе пола не заполнено\n" % VER
# Объявление ИНЕРТНЫХ правок (⊘ и ≡): дом -- репозиторий кита, владелец -- пара
# «версия + форк», как и у попыток. Объявляются ИМЕНА, а не числа: равный итог
# не означает равного состава, и подмену одного инертного имени другим счёт не
# двигает.
inert_v0 = "%s\t⊘\tpatch v0\tизмерено\n" % VER
inert_v1 = "%s\t⊘\tpatch v1\tизмерено\n" % VER
inert_n0 = "%s\t≡\tpatch n0\tизмерено\n" % VER
# Имя, объявленное НЕ ПОД ТЕМ знаком: счёт инертных тот же, состав другой.
inert_v0_as_noop = "%s\t≡\tpatch v0\tзнак перепутан\n" % VER
inert_row_nowhy = "%s\t⊘\tpatch v0\t\n" % VER
inert_row_placeholder = "%s\t⊘\tpatch v0\t<причина>\n" % VER
inert_row_other = "%s\t⊘\tpatch v0\tчужая версия\n" % NEIGHBOUR
# Строка без ИМЕНИ: набор имён её отбрасывает, а объявление на версию делает
# непустым -- дверь уходила в сверку наборов и на пустом измерении отвечала
# «сошлись с объявлением: 0, 0».
inert_row_noname = "%s\t⊘\t\tимя не вписано\n" % VER
# ≡, объявленный на имени, которое ЭТА машина измеряет кружком: оператор
# выключил тумблер в интерфейсе форка. Владельцев у ≡ трое, и эта сторона
# ослаблена ровно на такой исход.
inert_noop_on_off = "%s\t≡\tpatch o0\tтумблер выключен оператором\n" % VER
# ≡ на имени, измеренном галочкой: правка вернулась к жизни.
inert_noop_alive = "%s\t≡\tpatch 1\tбыло вхолостую на прошлой версии\n" % VER
# ≡ на имени, которого в выводе нет ни под одним знаком: правка ушла из реестра.
inert_noop_gone = "%s\t≡\tpatch zzz\tбыло вхолостую до переезда пина\n" % VER
# ⊘ на имени, измеренном кружком: у ⊘ послабления НЕТ -- его решает пара
# «версия + реестр форка», и конфиг машины ему не владелец.
inert_vskip_on_off = "%s\t⊘\tpatch o0\tверсия правку не несёт\n" % VER
# Уровень, объявленный НУЛЁМ: не уровень, а след сломанного прибора.
row_zero = "%s\t0\tизмерено\n" % VER
# Версия, на которой ничего не легло и ничего не упало: весь слой кода в
# ○/⊘/≡. Строк результата пять, и вывод разобран полностью.
row_five = "%s\t5\tизмерено\n" % VER


def run(body, table, out_text, marker=VER, blind=False, off_decl=None, floor=None,
        inert=None, origin=None):
    """off_decl/floor/inert: None -- сходящееся объявление, False -- файла нет
    вовсе, строка -- тело файла как есть.

    origin -- отметка происхождения дома: None означает, что файла НЕТ (дом с
    оператором: живой, клон живого, одолженный зондом), строка -- его тело.
    Пустая строка -- отдельный вход: файл есть, а утверждения в нём нет."""
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        tf = root / "expected.txt"
        tf.write_text(table, encoding="utf-8")
        vf = root / "expected-inert.txt"
        if inert is not False:
            vf.write_text(inert_body(out_text) if inert is None else inert,
                          encoding="utf-8")
        of = root / "tweakcc.out"
        of.write_text(out_text, encoding="utf-8")
        # Дом tweakcc -- ВРЕМЕННЫЙ. Оба объявления дома (множество выключенных
        # правок и пол слоя накладок) живут рядом с config.json, и оснастка,
        # заглянувшая в живой дом, мерила бы состояние машины оператора, а не
        # свой сценарий.
        home = root / "tweakcc-home"
        home.mkdir()
        off_file = home / "catalyst-expected-off.txt"
        if off_decl is not False:
            off_file.write_text(off_body(out_text) if off_decl is None else off_decl,
                                encoding="utf-8")
        floor_file = home / "catalyst-prompt-floor.txt"
        if floor is not False:
            floor_file.write_text(floor_here if floor is None else floor, encoding="utf-8")
        # Отметка происхождения дома. Имя -- то же, что кладёт свип; переменная
        # объявляется ВСЕГДА, потому что дверь читает её под `set -u`, а файл
        # создаётся только там, где сценарий его требует.
        origin_file = home / "catalyst-home-origin.txt"
        if origin is not None:
            origin_file.write_text(origin, encoding="utf-8")
        img = root / "image"
        marker_bytes = ("// Version: %s\n" % marker).encode() if marker else b"no version marker\n"
        img.write_bytes(b"\x00\x01binary\x00noise\x00" + marker_bytes + b"\x00tail\x00")
        env = "CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1\n" if blind else ""
        script = ("set -uo pipefail\n" + env
                  + "TWEAKCC_EXPECTED_APPLIED=%s\n" % shlex.quote(str(tf))
                  + "TWEAKCC_EXPECTED_INERT=%s\n" % shlex.quote(str(vf))
                  + "TWEAKCC_HOME=%s\n" % shlex.quote(str(home))
                  + "TWEAKCC_EXPECTED_OFF=%s\n" % shlex.quote(str(off_file))
                  + "TWEAKCC_EXPECTED_PROMPT_FLOOR=%s\n" % shlex.quote(str(floor_file))
                  + "TWEAKCC_HOME_ORIGIN=%s\n" % shlex.quote(str(origin_file))
                  + body
                  # Порядок дверей -- конвейерный: предбанник якоря (он задаёт
                  # ОБЛАСТЬ всем счётам), дверь читаемости вывода, уровень,
                  # множество выключенных. Отказ каждой до следующей не пускает.
                  + "\n__tw_check_anchor %s || exit $?\n" % shlex.quote(str(of))
                  + "__tw_check_result_rows %s || exit $?\n" % shlex.quote(str(of))
                  + "__tw_check_applied_level %s %s || exit $?\n"
                    % (shlex.quote(str(of)), shlex.quote(str(img)))
                  + "__tw_check_off_set %s %s\n"
                    % (shlex.quote(str(of)), shlex.quote(str(img))))
        # errors="replace": оснастка обязана пережить байты МУТАНТА. Мутация
        # N12 снимает проверку пола, и bash уходит в арифметику над кириллицей,
        # печатая диагностику, обрезанную посреди символа. Падение декодера
        # здесь неотличимо от «прибор сломался», а покраснеть обязана мутация.
        return subprocess.run(["bash"], input=script, capture_output=True, text=True, errors="replace")


# Вывод с выключенными правками: 12 легло, 1 не легло, 2 выключены -- те же
# пятнадцать попыток. Расклад РАЗНЫЙ при одном и том же числе попыток: ровно
# это и означает «число удач принадлежит машине, а число попыток -- версии».
out_with_off = out_rows(12, 21, 1, off=2)
# Накладка тоже умеет печататься кружком. Названа она НАРОЧНО как правка кода:
# в множество выключенных правок КОДА она не входит по СЕКЦИИ, а не по имени.
out_off_overlay = out_rows(12, 21, 1, off=2, extra_prompt=["○ patch o9"])

SCEN = {
    # Сошлись оба слоя: 15 попыток кода (14 легло, один непроход) и 21 промт --
    # крестик в счёт ЛЕГШИХ входить не должен, а в счёт попыток обязан; строки
    # накладок не должны попасть в код ни там, ни там. Приманки в выводе
    # означают, что этот же счёт доказывает атрибуцию по секции: разбор по
    # префиксу имени дал бы здесь 15 кода и 20 промтов.
    "N1": (row_here, out_rows(14, 21, 1), VER, False, None, None,
           lambda r: r.returncode == 0 and "сошёлся" in r.stderr
                     and "кода 14, промтов 21" in r.stderr
                     and "легло 14, выключено конфигурацией 0, пропущено по версии 0,"
                         " вхолостую 0, не легло 1" in r.stderr
                     and "не легло накладок 0" in r.stderr),
    "N2": (row_here, out_rows(9, 21), VER, False, None, None,
           lambda r: r.returncode == 1 and "слой кода tweakcc просел" in r.stderr
                     and "объявлено попыток 15, пробовалось 9" in r.stderr),
    # Число в предикате -- НЕ украшение: слияние секций даёт ту же дверь и то
    # же сообщение при другом счёте, и без числа зуб слияния красил бы зелёным.
    "N3": (row_here, out_rows(20, 21), VER, False, None, None,
           lambda r: r.returncode == 1 and "кода пробовалось БОЛЬШЕ объявленного" in r.stderr
                     and "объявлено 15, пробовалось 20" in r.stderr),
    "N4": ("", out_rows(14, 21), VER, False, None, None,
           lambda r: r.returncode == 1 and "не объявлен" in r.stderr
                     and ("%s\t14\t" % VER) in r.stderr),
    # Измерение даёт РОВНО те 15 попыток, что объявлены у соседней версии:
    # мутант, снявший версионный фильтр, обязан уйти зелёным (чужая строка
    # принята за свою), а не покраснеть просадкой уровня по чужой причине.
    "N5": (row_neighbour, out_rows(14, 21, 1), VER, False, None, None,
           lambda r: r.returncode == 1 and "не объявлен" in r.stderr),
    "N6": ("", out_rows(3, 4), VER, True, None, None,
           lambda r: r.returncode == 0 and "дверь уровня tweakcc погашена" in r.stderr),
    # Пол промтов пробит: слой перестал ложиться -- это ровно тот регресс,
    # которым кит владеет.
    "N7": (row_here, out_rows(14, 19, 1), VER, False, None, None,
           lambda r: r.returncode == 1 and "слой промтов tweakcc просел" in r.stderr
                     and "пол 21" in r.stderr),
    # Рост промтов -- НЕ красный: пользователь добавил накладки, дефекта нет.
    # Это и есть причина односторонности, и она обязана иметь свой сценарий.
    "N8": (row_here, out_rows(14, 30, 1), VER, False, None, None,
           lambda r: r.returncode == 0 and "сошёлся" in r.stderr and "промты 30" in r.stderr),
    # «нет-слоя» -- не пол 0, а требование ДВУСТОРОННЕГО нуля: оживший слой
    # обязан покраснеть, иначе запись переживает свою причину.
    "N9": (row_here, out_rows(14, 2, 1), VER, False, None, floor_nolayer,
           lambda r: r.returncode == 1 and "объявлен отсутствующим, но он ожил" in r.stderr),
    "N10": (row_here, out_rows(14, 0, 1), VER, False, None, floor_nolayer,
            lambda r: r.returncode == 0 and "сошёлся" in r.stderr),
    # Накладки, которых в образе не нашлось: не гейтятся (владелец -- каталог
    # пользователя), но обязаны быть НАЗВАНЫ. Молчание здесь и было дырой.
    "N11": (row_here, out_rows(14, 21, 1, 3), VER, False, None, None,
            lambda r: r.returncode == 0 and "не нашлось в образе: 3" in r.stderr
                      and "не найдена накладка: overlay m0" in r.stderr
                      and "не найдена накладка: overlay m2" in r.stderr),
    "N12": (row_here, out_rows(14, 21, 1), VER, False, None, floor_bad,
            lambda r: r.returncode == 1 and "пол промтов" in r.stderr and "не число" in r.stderr),
    # Ключ сверяется ТРИМЛЕННЫМ: строка, вписанная с отступом, принадлежит этой
    # версии, а не «чужой». Без трима дверь отвечала бы «не объявлен» на
    # объявление, которое человек уже сделал.
    "N13": (row_indented, out_rows(14, 21, 1), VER, False, None, None,
            lambda r: r.returncode == 0 and "сошёлся" in r.stderr),
    # Две строки на версию: читатель берёт первую и выходит, вторая (та, которую
    # правил человек) молча не действует -- отказ обязан назвать дубль.
    # Измерение сходится с ПЕРВОЙ строкой: мутант, снявший дверь дубля, обязан
    # уйти зелёным (вторая строка молча не действует), а не покраснеть уровнем.
    "N14": (row_here + row_here, out_rows(14, 21, 1), VER, False, None, None,
            lambda r: r.returncode == 1 and "приходится строк: 2" in r.stderr),
    # Строка ЕСТЬ, поле кода пусто: совет «впишите строку» дал бы вторую строку
    # на версию, то есть отправил бы чинить в отказ по дублю.
    "N15": (row_empty_code, out_rows(14, 21), VER, False, None, None,
            lambda r: r.returncode == 1 and "поле кода в ней пусто" in r.stderr
                      and "Строка ниже" not in r.stderr),
    # --- дверь МНОЖЕСТВА выключенных правок (владелец -- дом tweakcc) --------
    # Объявление сошлось с измеренным: попыток столько же, а расклад иной.
    "N16": (row_here, out_with_off, VER, False, None, None,
            lambda r: r.returncode == 0 and "сошёлся" in r.stderr
                      and "сошлись с объявлением дома: 2" in r.stderr),
    # Объявления нет вовсе, А ВЫКЛЮЧЕННЫЕ ЕСТЬ: отказ обязан нести ГОТОВОЕ тело
    # файла, а не одно первое имя -- иначе человек узнаёт о своём доме по одной
    # правке за прогон.
    "N17": (row_here, out_with_off, VER, False, False, None,
            lambda r: r.returncode == 1 and "не найдено" in r.stderr
                      and "patch o0" in r.stderr and "patch o1" in r.stderr),
    # Выключилось без объявления: конфиг дома изменился молча.
    "N18": (row_here, out_with_off, VER, False, "patch o0\n", None,
            lambda r: r.returncode == 1 and "не объявленные выключенными" in r.stderr
                      and "○ patch o1" in r.stderr and "а пробуются" not in r.stderr),
    # Объявлено, а пробуется: запись пережила причину и стала бы бессрочной
    # индульгенцией -- ровно так вернулся список старых моделей в /model.
    "N19": (row_here, out_with_off, VER, False, "patch o0\npatch o1\npatch 3\n", None,
            lambda r: r.returncode == 1 and "а пробуются" in r.stderr
                      and "patch 3" in r.stderr),
    # Оба направления разом: печатаются ОБА блока, и только потом отказ.
    "N20": (row_here, out_with_off, VER, False, "patch o0\npatch 3\n", None,
            lambda r: r.returncode == 1 and "не объявленные выключенными" in r.stderr
                      and "а пробуются" in r.stderr
                      and "○ patch o1" in r.stderr and "patch 3" in r.stderr),
    # Форма файла: комментарий, пустая строка, отступы по краям и дубль -- это
    # то же объявление, а не четыре разных.
    "N21": (row_here, out_with_off, VER, False,
            "# коммент\n\n  patch o0  \npatch o1\npatch o1\n", None,
            lambda r: r.returncode == 0 and "сошлись с объявлением дома: 2" in r.stderr),
    # Слепая ручка гасит и эту дверь -- но ОБЪЯВЛЕННО: молча снятая дверь
    # неотличима от двери, которая держится.
    "N22": (row_here, out_with_off, VER, True, False, None,
            lambda r: r.returncode == 0
                      and "дверь выключенных правок tweakcc погашена" in r.stderr),
    # Накладка с кружком принадлежит каталогу пользователя и в множество
    # выключенных правок КОДА не входит. Названа она как правка кода нарочно:
    # исключает её СЕКЦИЯ, а не форма имени.
    "N23": (row_here, out_off_overlay, VER, False, None, None,
            lambda r: r.returncode == 0 and "сошлись с объявлением дома: 2" in r.stderr),
    # --- часовой формы вывода -----------------------------------------------
    # Строка правки ДО первой секции: слоя у неё нет, и отнести её к любому
    # значило бы вернуть отказ по чужой причине.
    "N24": (row_here, out_rows(14, 21, 1, stray="    ✓ patch stray — ok\n"),
            VER, False, None, None,
            lambda r: r.returncode == 1
                      and "не принадлежащие ни одному счёту" in r.stderr
                      and "patch stray" in r.stderr),
    # Незнакомая ГРУППА форка: ровно тот случай, который апстрим и заведёт --
    # восьмая группа обязана быть объявлена, а не разойтись по счётам молча.
    "N25": (row_here, out_rows(14, 21, 1, unknown=[("Brand New Group", ["✓ patch nine — ok"])]),
            VER, False, None, None,
            lambda r: r.returncode == 1
                      and "не принадлежащие ни одному счёту" in r.stderr
                      and "patch nine" in r.stderr),
    # Слепая ручка гасит и этот отказ: её ранний возврат стоит ВЫШЕ отказов, и
    # расклад печатается до него -- порядок «расклад, ручка, отказы» и есть
    # предмет сценария.
    "N26": (row_here, out_rows(14, 21, 1, stray="    ✓ patch stray — ok\n"),
            VER, True, None, None,
            lambda r: r.returncode == 0 and "дверь уровня tweakcc погашена" in r.stderr
                      and "часовой формы вывода tweakcc погашен" in r.stderr),
    # --- сходимость нулевых множеств ----------------------------------------
    # Объявления выключенных правок нет И выключенных не измерено: отсутствующий
    # файл -- это ПУСТОЕ объявленное множество, оно сходится с пустым измеренным
    # обеими сторонами. Отказ здесь красил бы свежую машину и пустой дом клона.
    "N27": (row_here, out_rows(14, 21, 1), VER, False, False, None,
            lambda r: r.returncode == 0
                      and "выключенных правок не измерено (0) -- сходится" in r.stderr),
    # BOM первой строки объявления: `[[:space:]]` его не берёт, и файл из
    # редактора давал ОБА блока отказа сразу на двух визуально одинаковых именах.
    "N28": (row_here, out_with_off, VER, False, "\ufeffpatch o0\npatch o1\n", None,
            lambda r: r.returncode == 0 and "сошлись с объявлением дома: 2" in r.stderr),
    # --- пол слоя промтов в доме МАШИНЫ -------------------------------------
    # Файла пола нет и слоя нет: сходится, как и пустое множество выключенных.
    "N29": (row_here, out_rows(14, 0, 1), VER, False, None, False,
            lambda r: r.returncode == 0
                      and "не объявлен, и слоя нет (легло 0, не найдено 0, не легло 0)"
                          " -- сходится" in r.stderr),
    # Файла пола нет, а слой измерен: отказ обязан назвать ФАЙЛ и напечатать
    # готовую строку -- пол принадлежит дому, и человеку чинить именно там.
    "N30": (row_here, out_rows(14, 21, 1), VER, False, None, False,
            lambda r: r.returncode == 1 and "не объявлен: " in r.stderr
                      and ("%s\t21\t" % VER) in r.stderr),
    # Две строки на версию в доме пола: читатель берёт первую и выходит.
    "N31": (row_here, out_rows(14, 21, 1), VER, False, None, floor_here + floor_here,
            lambda r: r.returncode == 1 and "приходится строк: 2" in r.stderr),
    # BOM первой строки файла пола -- та же метка, тот же снимок.
    "N32": (row_here, out_rows(14, 21, 1), VER, False, None, "\ufeff" + floor_here,
            lambda r: r.returncode == 0 and "сошёлся" in r.stderr),
    # --- крестики слоя НАКЛАДОК (волна 39c) ---------------------------------
    # Их не читал никто: сверка непроходов разбирает слой КОДА, и полный обвал
    # слоя накладок -- всё легло, всё объявлено непрошедшим -- проходил молча.
    # Пол промтов удовлетворён (легло 21 при поле 21): мутант, снявший ЭТУ
    # дверь, обязан уйти зелёным, а не покраснеть просевшим полом -- иначе зуб
    # доказывает соседнее правило.
    "N33": (row_here, out_rows(14, 21, 1, pfail=2), VER, False, None, None,
            lambda r: r.returncode == 1
                      and "накладки промтов tweakcc объявлены НЕ ЛЕГШИМИ: 2" in r.stderr
                      and "overlay p0" in r.stderr),
    # Крестик накладки НЕ уходит в счёт кода: слой различается секцией, и число
    # непроходов кода при этом остаётся своим.
    "N34": (row_here, out_rows(14, 21, 1, pfail=1), VER, True, None, None,
            lambda r: r.returncode == 0
                      and "дверь непрошедших накладок tweakcc погашена (не легло накладок 1)" in r.stderr),
    # --- ИНЕРТНЫЕ правки: ⊘ и ≡ ПОИМЁННО -------------------------------------
    # Знак ≡ НЕ означает промах локатора: в форке есть умышленный ранний возврат
    # «на этой версии делать нечего» (worktreeMode.ts:29, mcpStartup.ts:130), и
    # безусловный отказ на ≡ краснил ЗДОРОВЫЙ прогон 2.1.261. Предмет двери --
    # ОБЪЯВЛЕННЫЙ НАБОР ИМЁН, как у соседних дверей кита.
    #
    # Объявление сошлось обеими сторонами и обоими знаками: попыток те же 15,
    # расклад иной -- две правки версия не несёт вовсе, одна отработала
    # вхолостую. До раскола знаков все три печатались кружком и числились
    # выключенными конфигурацией ЧУЖОГО дома.
    # Расклад читается из строки ДВЕРИ УРОВНЯ, и подстрока берётся вместе с
    # соседним полем («не легло»): те же два числа теперь называет и голос
    # двери инертных, и короткий образец сошёлся бы с ЛЮБЫМ из двух носителей --
    # мутация, гасящая расклад уровня, оставалась бы зелёной.
    "N35": (row_here, out_rows(11, 21, 1, vskip=2, noop=1), VER, False, None, None, None,
            lambda r: r.returncode == 0 and "сошёлся" in r.stderr
                      and "пропущено по версии 2, вхолостую 1, не легло" in r.stderr),
    "N36": (row_here, out_rows(13, 21, 1, noop=1), VER, True, None, None, None,
            lambda r: r.returncode == 0
                      and "дверь инертных правок tweakcc погашена" in r.stderr
                      and "вхолостую 1" in r.stderr),
    # ⊘ измерено, но НЕ объявлено: форк перестал нести данные ещё под одну
    # правку, и без двери это прошло бы молча.
    "N37": (row_here, out_rows(11, 21, 1, vskip=2, noop=1), VER, False, None, None,
            inert_v0 + inert_n0,
            lambda r: r.returncode == 1
                      and "«пропущено по версии», которых нет в объявлении" in r.stderr
                      and "patch v1" in r.stderr),
    # ⊘ объявлено, но НЕ измерено: запись пережила свою причину -- вторая
    # сторона двери, без которой объявление стало бы бессрочной индульгенцией.
    "N38": (row_here, out_rows(12, 21, 1, vskip=1, noop=1), VER, False, None, None,
            inert_v0 + inert_v1 + inert_n0,
            lambda r: r.returncode == 1
                      and "«пропущено по версии», которых нет в реестре форка" in r.stderr
                      and "patch v1" in r.stderr),
    # ≡ измерено, но НЕ объявлено: у своего знака своя сверка. Одна сверка на
    # оба знака приняла бы ⊘, ушедшее в ≡, за сходимость.
    "N39": (row_here, out_rows(11, 21, 1, vskip=2, noop=1), VER, False, None, None,
            inert_v0 + inert_v1,
            lambda r: r.returncode == 1
                      and "«отработало вхолостую», которых нет в объявлении" in r.stderr
                      and "patch n0" in r.stderr),
    # ≡ объявлено, но НЕ измерено.
    "N40": (row_here, out_rows(12, 21, 1, vskip=2), VER, False, None, None,
            inert_v0 + inert_v1 + inert_n0,
            lambda r: r.returncode == 1
                      and "«отработало вхолостую», которых нет в реестре форка" in r.stderr
                      and "patch n0" in r.stderr),
    # Имя объявлено НЕ ПОД ТЕМ знаком: инертных по-прежнему двое, состав другой.
    # Дверь на ЧИСЛЕ такую подмену пропустила бы молча -- ровно поэтому
    # объявляются имена, а не счёт.
    "N41": (row_here, out_rows(12, 21, 1, vskip=1, noop=1), VER, False, None, None,
            inert_v0_as_noop + inert_n0,
            lambda r: r.returncode == 1
                      and "«пропущено по версии», которых нет в объявлении" in r.stderr
                      and "patch v0" in r.stderr),
    # Дубль пары «версия+знак+имя»: sort -u схлопнул бы вторую строку, и правка
    # человека молча не действовала бы.
    "N42": (row_here, out_rows(12, 21, 1, vskip=1, noop=1), VER, False, None, None,
            inert_v0 + inert_v0 + inert_n0,
            lambda r: r.returncode == 1 and "объявлена дважды" in r.stderr
                      and "patch v0" in r.stderr),
    # Причина ОБЯЗАТЕЛЬНА -- тот же зуб, что у пола промтов: строку нельзя
    # вклеить, не написав, откуда она взялась.
    "N43": (row_here, out_rows(12, 21, 1, vskip=1, noop=1), VER, False, None, None,
            inert_row_nowhy + inert_n0,
            lambda r: r.returncode == 1 and "без названной причины" in r.stderr),
    # Оставленная дословно заготовка совета -- то же утверждение без причины.
    "N44": (row_here, out_rows(12, 21, 1, vskip=1, noop=1), VER, False, None, None,
            inert_row_placeholder + inert_n0,
            lambda r: r.returncode == 1 and "без названной причины" in r.stderr),
    # --- часовой ЗНАКОВ -----------------------------------------------------
    # Знак вне известного набора под ИЗВЕСТНОЙ секцией: его не считает ни один
    # класс, то есть попытка исчезает из всех счётов разом. Прежний часовой
    # перечислял знаки регекспом и такой строки не видел вовсе.
    "N45": (row_here,
            out_rows(14, 21, 1, unknown=[("Always Applied", ["★ patch six — new sign"])]),
            VER, False, None, None,
            lambda r: r.returncode == 1
                      and "не принадлежащие ни одному счёту" in r.stderr
                      and "patch six" in r.stderr),
    # --- пол: две ветки совета ----------------------------------------------
    # Файл пола ЕСТЬ, строки под эту версию нет: совет обязан дать готовую
    # строку -- ветка «строка есть, поле пусто» отправила бы человека править
    # то, чего в файле нет.
    "N46": (row_here, out_rows(14, 21, 1), VER, False, None, floor_other,
            lambda r: r.returncode == 1 and "пол слоя промтов не объявлен" in r.stderr
                      and "Строка ниже" in r.stderr and ("%s\t21\t" % VER) in r.stderr),
    # Строка на версию ЕСТЬ, поле пола пусто: готовая строка дала бы вторую
    # строку на версию, то есть отказ по дублю на следующем прогоне.
    "N47": (row_here, out_rows(14, 21, 1), VER, False, None, floor_empty_field,
            lambda r: r.returncode == 1 and "поле пола в ней пусто" in r.stderr
                      and "Строка ниже" not in r.stderr),
    # --- пол: происхождение числа обязательно -------------------------------
    # Дом пола вне контроля версий, а отказ печатает готовую строку с ТЕКУЩИМ
    # измерением: вклеенная без причины, она восстанавливает пол на просевшем
    # уровне и стирает сигнал бесследно.
    "N48": (row_here, out_rows(14, 21, 1), VER, False, None, floor_nowhy,
            lambda r: r.returncode == 1
                      and "не называет ПРОИСХОЖДЕНИЕ числа" in r.stderr),
    # Заглушка совета, оставленная дословно, -- то же самое число без причины.
    "N49": (row_here, out_rows(14, 21, 1), VER, False, None, floor_placeholder,
            lambda r: r.returncode == 1
                      and "не называет ПРОИСХОЖДЕНИЕ числа" in r.stderr),
    # --- BOM файла КИТА ------------------------------------------------------
    # Метку порядка байтов снимали два новых читателя пола и не снимали три
    # старых: файл из редактора давал «версия не объявлена» на строке, которая
    # на экране выглядит правильной.
    # Счётчик строк файла кита: с непрочитанной меткой дубль на версию виден
    # ему как одна строка, и дверь дубля молчит.
    "N50": ("\ufeff" + row_here + row_here, out_rows(14, 21, 1), VER, False, None, None,
            lambda r: r.returncode == 1 and "приходится строк: 2" in r.stderr),
    # Читатель ЗНАЧЕНИЯ файла кита: с непрочитанной меткой строка первой версии
    # читается как чужая, и дверь отвечает «не объявлен» на объявление, которое
    # человек уже сделал.
    "N51": ("\ufeff" + row_here, out_rows(14, 21, 1), VER, False, None, None,
            lambda r: r.returncode == 0 and "сошёлся" in r.stderr),
    # --- ОГРАНИЧЕНИЕ ОБЛАСТИ: предапплайный список плана ---------------------
    # Форк печатает ДВА блока правок под ОДНИМИ И ТЕМИ ЖЕ заголовками секций:
    # список ПЛАНА (applyPlan.ts:269, «    • Имя (id) [default-on]») и
    # РЕЗУЛЬТАТЫ (index.tsx:124). Формой они неразличимы, и часовой знаков,
    # спрашивавший незнакомый знак под известной секцией, отказывал на ЗДОРОВОМ
    # прогоне 2.1.261 -- то есть краснил по чужой причине. Лечится ГРАНИЦЕЙ
    # предмета, а не оговоркой: всё до якоря читателям не принадлежит.
    "N52": (row_here,
            out_rows(14, 21, 1,
                     plan=sec("Always Applied",
                              ["• Verbose property (verbose-property) [default-on]",
                               "• Opusplan support (opusplan1m) [default-on]"])),
            VER, False, None, None, None,
            lambda r: r.returncode == 0 and "сошёлся" in r.stderr),
    # --- ЕДИНСТВЕННОСТЬ ЯКОРЯ -----------------------------------------------
    # Ноль якорей: форк сменил строку, открывающую блок. Область пуста, каждый
    # счёт даёт ноль, и дверь уровня обвинила бы РЕЕСТР ФОРКА вместо формы
    # вывода -- отказ по чужой причине с точностью до наоборот.
    "N53": (row_here, out_rows(14, 21, 1, anchors=0), VER, False, None, None, None,
            lambda r: r.returncode == 1
                      and "якорь блока результатов tweakcc встречается 0 раз" in r.stderr),
    # Два якоря: в один вывод слились два прогона tweakcc, и счёта сложились бы
    # по двум сборкам сразу.
    "N54": (row_here, out_rows(14, 21, 1, anchors=2), VER, False, None, None, None,
            lambda r: r.returncode == 1 and "встречается 2 раз" in r.stderr),
    # Гашение слепой ручкой ОБЪЯВЛЯЕТСЯ и у этой двери: снятая молча, она
    # неотличима от двери, которая держится.
    "N55": (row_here, out_rows(14, 21, 1, anchors=0), VER, True, None, None, None,
            lambda r: r.returncode == 0
                      and "дверь якоря блока результатов tweakcc погашена" in r.stderr),
    # --- инертные: строк под версию нет вовсе -------------------------------
    # Ни объявления, ни измерения -- СХОДИМОСТЬ, а не отказ: обе стороны
    # согласны, и отказ красил бы версию, на которой ничего не сломано.
    "N56": (row_here, out_rows(14, 21, 1), VER, False, None, None, inert_row_other,
            lambda r: r.returncode == 0 and "сошёлся" in r.stderr
                      and "не объявлено и не измерено" in r.stderr),
    # Строк нет, а инертные измерены: отказ обязан напечатать ГОТОВЫЕ к вклейке
    # строки ОБОИХ знаков -- набор к соседней версии не переносится.
    "N57": (row_here, out_rows(11, 21, 1, vskip=2, noop=1), VER, False, None, None,
            inert_row_other,
            lambda r: r.returncode == 1
                      and "инертные правки tweakcc не объявлены" in r.stderr
                      and ("%s\t⊘\tpatch v0\t" % VER) in r.stderr
                      and ("%s\t≡\tpatch n0\t" % VER) in r.stderr),
    # BOM первой строки объявления инертных -- та же метка, тот же приём.
    "N58": (row_here, out_rows(12, 21, 1, vskip=1, noop=1), VER, False, None, None,
            "\ufeff" + inert_v0 + inert_n0,
            lambda r: r.returncode == 0 and "сошёлся" in r.stderr),
    # --- голос двери на УСПЕХЕ ----------------------------------------------
    # Дверь, сходящаяся молча, побайтово неотличима от снятой: до этой правки
    # успешная двусторонняя сходимость не печатала ничего, и снятие обеих
    # сверок не меняло ни лога, ни вердикта. Строка обязана назвать версию,
    # ОБА числа и ФАЙЛ объявления -- числа без дома не говорят, с чем сошлись.
    "N59": (row_here, out_rows(11, 21, 1, vskip=2, noop=1), VER, False, None, None, None,
            lambda r: r.returncode == 0
                      and "инертные правки tweakcc на %s сошлись с объявлением: пропущено по версии 2, вхолостую 1" % VER in r.stderr
                      and "expected-inert.txt" in r.stderr),
    # Гашение слепой ручкой объявляется БЕЗ УСЛОВИЯ: голос двери читает и поле
    # вердикта свипа, а поле, замолкающее там, где гасить было нечего, от
    # снятой двери неотличимо. Инертных здесь не измерено ни одного.
    "N60": (row_here, out_rows(14, 21, 1), VER, True, None, None, None,
            lambda r: r.returncode == 0
                      and "дверь инертных правок tweakcc погашена (пропущено по версии 0, вхолостую 0)" in r.stderr),
    # --- ВЛАДЕЛЕЦ ЗНАКА ≡: конфиг машины, а не только версия и реестр --------
    # В цикле применения форка проверка конфига (○) стоит ПЕРЕД исполнением,
    # поэтому ≡ достижим только там, где оператор оставил правку включённой.
    # Выключил тумблер -- имя измерено кружком, и сторона «объявлено, но не
    # измерено» МОЛЧИТ: исход гейтится дверью множества выключенных, чей дом --
    # машина. Прежде здесь был ложный отказ, и лечение он советовал такое,
    # которое ломает машину с включённым тумблером.
    "N61": (row_here, out_with_off, VER, False, None, None, inert_noop_on_off,
            lambda r: r.returncode == 0
                      and "инертные правки tweakcc на %s сошлись с объявлением" % VER in r.stderr),
    # Та же сторона, но имя измерено ГАЛОЧКОЙ: отказ СВОЕЙ причиной.
    "N62": (row_here, out_rows(14, 21, 1), VER, False, None, None, inert_noop_alive,
            lambda r: r.returncode == 1 and "а они снова работают" in r.stderr
                      and "patch 1" in r.stderr),
    # ...и имя, которого в выводе нет вовсе: другая причина, другое лечение.
    "N63": (row_here, out_rows(14, 21, 1), VER, False, None, None, inert_noop_gone,
            lambda r: r.returncode == 1 and "которых нет в реестре форка" in r.stderr
                      and "patch zzz" in r.stderr),
    # --- голоса часового формы и двери накладок (безусловные) ---------------
    # Дверь, молчащая на здоровом прогоне, побайтово неотличима от снятой, и
    # поля вердикта свипа читают именно эти две строки.
    "N64": (row_here, out_rows(14, 21, 1), VER, False, None, None, None,
            lambda r: r.returncode == 0
                      and ("NOTE: часовой формы строк tweakcc на %s: строк вне известных секций 0" % VER) in r.stderr
                      and ("NOTE: накладки промтов tweakcc на %s: объявленных не легшими 0" % VER) in r.stderr),
    # Слепая ручка гасит обе, и обе объявляют гашение БЕЗ УСЛОВИЯ: строка,
    # замолкающая там, где гасить было нечего, от снятой двери неотличима.
    "N65": (row_here, out_rows(14, 21, 1), VER, True, None, None, None,
            lambda r: r.returncode == 0
                      and "часовой формы вывода tweakcc погашен (строк вне известных секций либо с незнакомым знаком: 0)" in r.stderr
                      and "дверь непрошедших накладок tweakcc погашена (не легло накладок 0)" in r.stderr),
    # --- знак ИЗ ASCII под известной секцией ---------------------------------
    # Форма строки правки требовала байта вне ASCII, и такая строка не
    # доставалась НИКОМУ: ни счётам, ни часовому. Первой говорила дверь уровня,
    # обвиняя реестр форка вместо формы вывода.
    "N66": (row_here,
            out_rows(14, 21, 1, unknown=[("Always Applied", ["- Thinking block styling"])]),
            VER, False, None, None, None,
            lambda r: r.returncode == 1
                      and "не принадлежащие ни одному счёту" in r.stderr
                      and "Thinking block styling" in r.stderr),
    # --- обвал слоя накладок на машине БЕЗ объявленного пола ------------------
    # Дом пола -- машина, и на свежей его нет вовсе. Дверь непрошедших накладок
    # стоит ВЫШЕ пола и отвечает первой: полный обвал слоя (всё легло, всё
    # объявлено непрошедшим) даёт легло 0 и не найдено 0, то есть выглядит как
    # «слоя нет».
    "N67": (row_here, out_rows(14, 0, 1, pfail=2), VER, False, None, False, None,
            lambda r: r.returncode == 1
                      and "накладки промтов tweakcc объявлены НЕ ЛЕГШИМИ: 2" in r.stderr
                      and "overlay p0" in r.stderr),
    # --- область блока результатов у СЧИТАЮЩЕГО читателя ---------------------
    # Считаемый знак ДО якоря: предапплайный список плана печатается под теми же
    # заголовками секций, и читатель без границы области посчитал бы его в
    # попытки. Мутация области у часового этого не ловит -- у него другой счёт.
    "N68": (row_here,
            out_rows(14, 21, 1, plan=sec("Always Applied", ["✓ patch plan1 — ok"])),
            VER, False, None, None, None,
            lambda r: r.returncode == 0 and "сошёлся" in r.stderr
                      and "попыток по слою кода 15" in r.stderr),
    # --- объявленный уровень НОЛЬ --------------------------------------------
    # Ноль не уровень: слой кода из десятков правок не может иметь ноль
    # попыток. Без этой двери объявление «0» сходилось бы с исчезнувшим слоем
    # обеими сторонами, а инертные и множество сходились бы пустотой -- прогон
    # с пропавшим слоем кода уходил бы зелёным.
    "N69": (row_zero, out_rows(0, 21), VER, False, None, None, None,
            lambda r: r.returncode == 1
                      and ("объявленный уровень кода для %s -- ноль" % VER) in r.stderr),
    # Совет двери на измеренном нуле не печатает готовую строку: вклеенная, она
    # закрыла бы дверь на нуле навсегда.
    "N70": ("", out_rows(0, 21), VER, False, None, None, None,
            lambda r: r.returncode == 1 and "Измерено НОЛЬ попыток" in r.stderr
                      and ("%s\t0\t" % VER) not in r.stderr),
    # --- строка объявления инертных с пустым ИМЕНЕМ --------------------------
    "N71": (row_here, out_rows(14, 21, 1), VER, False, None, None, inert_row_noname,
            lambda r: r.returncode == 1 and "без ИМЕНИ правки" in r.stderr),
    # --- версия, где ничего не легло и ничего не упало ------------------------
    # Весь слой кода в ○/⊘/≡: строк результата пять, вывод разобран полностью, и
    # объявлять его непрочитанным -- ложный отказ. Сырой образец `^    [✓✗] `
    # именно это и делал.
    "N72": (row_five, out_rows(0, 0, off=2, vskip=2, noop=1), VER, False, None,
            floor_nolayer, None,
            lambda r: r.returncode == 0 and "сошёлся" in r.stderr
                      and "попыток по слою кода 5" in r.stderr),
    # Ни одной строки результата и ВЗВЕДЁННАЯ ручка: дверь читаемости гасится, и
    # гашение объявляется. Прежде здесь не исполнялась ни одна ветка и не
    # печаталось ничего.
    "N73": (row_here, out_rows(0, 0), VER, True, None, None, None,
            lambda r: r.returncode == 0
                      and "дверь читаемости вывода tweakcc погашена (строк результата 0)" in r.stderr),
    # --- у ⊘ послабления НЕТ --------------------------------------------------
    # Имя, объявленное ⊘ и измеренное кружком: знак ⊘ решает пара «версия +
    # реестр форка», конфиг машины ему не владелец, и обе стороны отказывают.
    "N74": (row_here, out_with_off, VER, False, None, None, inert_vskip_on_off,
            lambda r: r.returncode == 1 and "измерены под другим знаком" in r.stderr
                      and "patch o0" in r.stderr),
    # --- дом, созданный ПРОГОНОМ, а не оператором ----------------------------
    # Предмет двери множества -- ДРЕЙФ конфига во времени. У дома, который свип
    # создаёт заново каждый прогон (живого дома на машине нет), оси времени
    # нет: выключено в нём то, что гасят дефолты форка. Отметка есть,
    # объявления нет, выключенных двое -- проход с NOTE, а не отказ; иначе
    # свежая машина краснеет без единого дефекта.
    "N75": (row_here, out_with_off, VER, False, False, None, None,
            "sweep-created 2026-09-06T00:00:00Z abc1234\n",
            lambda r: r.returncode == 0
                      and "создан прогоном, а не оператором" in r.stderr
                      and "sweep-created 2026-09-06T00:00:00Z abc1234" in r.stderr
                      and "выключено конфигурацией 2" in r.stderr
                      and "дефолты форка" in r.stderr),
    # ГРАНИЦА послабления. Тот же вход БЕЗ отметки -- прежний отказ без единого
    # изменения: дом с оператором обязан объявлять своё множество, и послабление
    # к нему не относится. Без этого пина «отметка» тихо стала бы «всегда».
    "N76": (row_here, out_with_off, VER, False, False, None, None, None,
            lambda r: r.returncode == 1
                      and "объявление выключенных правок tweakcc для дома" in r.stderr
                      and "не найдено" in r.stderr
                      and "создан прогоном" not in r.stderr),
    # Отметка ЕСТЬ, а утверждения в ней нет: пустой файл не говорит ничего, и
    # ключом к послаблению он быть не может.
    "N77": (row_here, out_with_off, VER, False, False, None, None, "",
            lambda r: r.returncode == 1
                      and "объявление выключенных правок tweakcc для дома" in r.stderr
                      and "не найдено" in r.stderr
                      and "создан прогоном" not in r.stderr),
}
ORDER = ["N1", "N2", "N3", "N4", "N5", "N6", "N7", "N8", "N9", "N10", "N11", "N12",
         "N13", "N14", "N15", "N16", "N17", "N18", "N19", "N20", "N21", "N22",
         "N23", "N24", "N25", "N26", "N27", "N28", "N29", "N30", "N31", "N32",
         "N33", "N34", "N35", "N36", "N37", "N38", "N39", "N40", "N41", "N42",
         "N43", "N44", "N45", "N46", "N47", "N48", "N49", "N50", "N51", "N52",
         "N53", "N54", "N55", "N56", "N57", "N58", "N59", "N60", "N61", "N62",
         "N63", "N64", "N65", "N66", "N67", "N68", "N69", "N70", "N71", "N72",
         "N73", "N74", "N75", "N76", "N77"]

mutations = [
    ("N1-cross-counted",
     "__tw_layer_names \"$1\" code '✓'", "__tw_layer_names \"$1\" code '✓✗'", "N1"),
    # Счётчик попыток обязан считать ВСЕ три исхода: оставь ему одни галочки --
    # и число попыток снова станет числом удач, то есть свойством машины.
    # Якорь с ХВОСТОМ счётчика: тот же вызов стоит и у читателя строк
    # результата (оба слоя), и голое имя брало бы два места разом.
    ("N1-tried-counts-only-ticks",
     '__tw_layer_names "$1" code "$TW_MARKS" | LC_ALL=C grep',
     "__tw_layer_names \"$1\" code '✓' | LC_ALL=C grep", "N1"),
    ("N1-agreement-silent", 'echo "NOTE: уровень tweakcc на $__ver сошёлся:', 'true "', "N1"),
    ("N2-low-door-off", "if (( __tried < __want_tried )); then", "if false; then", "N2"),
    ("N3-high-door-off", "if (( __tried > __want_tried )); then", "if false; then", "N3"),
    # Слой обязан различаться СЕКЦИЕЙ: отдай слою кода ещё и секцию накладок --
    # и счёт кода вырастет до полного объединения секций (20 + 21). Владелец --
    # сценарий БЕЗ крестиков: там, где крестик кода есть, слитый слой первой
    # видит дверь накладок, и зуб пинил бы её вместо счёта кода.
    ("N3-code-swallows-prompts",
     'if [[ "$__layer" == "code" ]]; then __secs="$__TW_CODE_SECTIONS"; else __secs="$__TW_PROMPT_SECTIONS"; fi',
     '__secs="$__TW_CODE_SECTIONS\t$__TW_PROMPT_SECTIONS"', "N3"),
    # Снятая ветка не делает прогон зелёным: пустое значение падает в соседний
    # числовой страж той же двери, и оператор получает жалобу на «не число»
    # вместо готовой строки. Предмет ветки -- СОВЕТ, и её отсутствие видно
    # именно по подмене сообщения, а не по коду выхода.
    ("N4-missing-row-unadvised", 'if [[ -z "$__want_tried" ]]; then', "if false; then", "N4"),
    # Якорь берётся С ОТСТУПОМ: тот же разбор строки стоит и у читателя пола, и
    # без отступа совпадений было бы два.
    ("N5-version-filter-off",
     '\n      k==v { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit }',
     '\n      1 { print $2; exit }', "N5"),
    ("N6-blind-knob-silent",
     'echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь уровня tweakcc погашена', 'true "', "N6"),
    ("N7-prompt-floor-off", "elif (( __prompts < __want_prompts )); then", "elif false; then", "N7"),
    # Пол обязан быть ОДНОСТОРОННИМ: равенство вернуло бы ровно тот дефект,
    # ради которого слои разделены -- красное на добавлении накладки.
    ("N8-floor-made-two-sided", "elif (( __prompts < __want_prompts )); then",
     "elif (( __prompts != __want_prompts )); then", "N8"),
    ("N9-nolayer-door-off",
     "if (( __prompts > 0 || __nf > 0 || __pfail > 0 )); then", "if false; then", "N9"),
    # Маркер обязан ПРИНИМАТЬ настоящее отсутствие слоя: отказ на нуле сделал бы
    # объявление невыполнимым, и человеку осталось бы только стереть строку.
    ("N10-nolayer-refuses-zero",
     "if (( __prompts > 0 || __nf > 0 || __pfail > 0 )); then", "if true; then", "N10"),
    ("N11-notfound-silent", 'echo "NOTE: накладок промтов не нашлось в образе:', 'true "', "N11"),
    ("N12-floor-validation-off", 'elif [[ ! "$__want_prompts" =~ ^[0-9]+$ ]]; then', "elif false; then", "N12"),
    # Якорь берётся ДВУМЯ строками И с отступом: тримом ключа заняты три
    # читателя, и одной строки не хватило бы на единственное совпадение.
    ("N13-key-trim-off",
     '{ k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k) }\n'
     '      k==v { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit }',
     '{ k=$1 }\n'
     '      k==v { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit }', "N13"),
    ("N14-duplicate-door-off", "if (( __rows > 1 )); then", "if false; then", "N14"),
    ("N15-empty-field-misadvised", "if (( __rows == 0 )); then", "if true; then", "N15"),
    # --- дверь множества выключенных правок ---------------------------------
    ("N16-off-agreement-silent",
     'echo "NOTE: выключенные конфигурацией правки tweakcc на $__ver сошлись', 'true "', "N16"),
    # Та же подмена ветки внутри ОДНОЙ двери: без проверки на отсутствие файла
    # сверка идёт с пустым объявлением, и человека посылают объявлять
    # выключенные вместо того, чтобы назвать пропавшее объявление.
    ("N17-missing-decl-unnamed", 'if [[ ! -f "$TWEAKCC_EXPECTED_OFF" ]]; then', "if false; then", "N17"),
    ("N18-undeclared-off-ok", 'if [[ -n "$__undeclared" ]]; then', "if false; then", "N18"),
    ("N19-stale-decl-ok", 'if [[ -n "$__stale" ]]; then', "if false; then", "N19"),
    # Отказ ПОСЛЕ обоих блоков: ранний возврат назвал бы человеку одну половину
    # встречного расхождения и отправил бы чинить дважды. Мутация красит именно
    # встречный сценарий -- односторонние от неё не меняются.
    ("N20-refuses-after-first-block",
     'которой в образе НЕТ." >&2\n    __bad=1',
     'которой в образе НЕТ." >&2\n    return 1', "N20"),
    ("N21-decl-not-trimmed",
     "| LC_ALL=C sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \\",
     "| LC_ALL=C cat \\", "N21"),
    ("N22-off-blind-silent",
     'echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь выключенных правок tweakcc погашена',
     'true "', "N22"),
    ("N23-off-swallows-overlays",
     "__tw_layer_names \"$1\" code '○'", "__tw_layer_names \"$1\" prompt '○'", "N23"),
    # --- часовой формы вывода -----------------------------------------------
    # Часового мало ПОСТАВИТЬ -- его надо СПРОСИТЬ: снятый вопрос возвращает
    # молчаливое расползание строк по счётам.
    ("N24-sentinel-not-consulted",
     'if [[ -n "$__unsect" ]]; then\n    echo "FATAL: строки правок tweakcc',
     'if false; then\n    echo "FATAL: строки правок tweakcc', "N24"),
    # А сам часовой обязан ВИДЕТЬ: ослепи его -- и он ответит пустотой, которую
    # дверь примет за «всё в известных секциях».
    ("N25-sentinel-blind",
     '      if ((cur in want) && index(marks, mark) > 0) next\n      print',
     '      if ((cur in want) && index(marks, mark) > 0) next\n      next', "N25"),
    # --- сходимость нулевых множеств ----------------------------------------
    ("N27-empty-set-refuses", "if (( __off == 0 )); then", "if false; then", "N27"),
    ("N28-off-bom-kept",
     'LC_ALL=C sed $\'1s/^\\xef\\xbb\\xbf//\' "$TWEAKCC_EXPECTED_OFF"',
     'LC_ALL=C cat "$TWEAKCC_EXPECTED_OFF"', "N28"),
    # --- пол слоя промтов в доме машины -------------------------------------
    ("N29-floor-zero-refuses",
     "if (( __prompts == 0 && __nf == 0 && __pfail == 0 )); then", "if false; then", "N29"),
    # Отказ обязан НАЗВАТЬ дом пола: без имени файла человек чинит вслепую,
    # а величина живёт не в репозитории кита.
    ("N30-floor-missing-unnamed",
     'echo "FATAL: пол слоя промтов tweakcc для дома $TWEAKCC_HOME не объявлен:', 'true "', "N30"),
    ("N31-floor-duplicate-ok", "if (( __floor_rows > 1 )); then", "if false; then", "N31"),
    ("N32-floor-bom-kept",
     '__want_prompts="$(LC_ALL=C sed $\'1s/^\\xef\\xbb\\xbf//\' "$TWEAKCC_EXPECTED_PROMPT_FLOOR"',
     '__want_prompts="$(LC_ALL=C cat "$TWEAKCC_EXPECTED_PROMPT_FLOOR"', "N32"),
    # --- ранний возврат слепой ручки ----------------------------------------
    # Ручка обязана ВЕРНУТЬСЯ, а не просто напечатать: оставь её без возврата --
    # и погашенные ею отказы сработают следом, то есть гашения не будет вовсе.
    ("N26-blind-knob-falls-through",
     'дверь уровня tweakcc погашена (попыток $__tried, легло $__code, промтов $__prompts)" >&2\n    return 0',
     'дверь уровня tweakcc погашена (попыток $__tried, легло $__code, промтов $__prompts)" >&2\n    :', "N26"),
    # Каждая погашенная дверь объявляется СВОЕЙ строкой: одно общее «уровень
    # погашен» умалчивало, что вместе с ним снят и часовой формы.
    ("N26-sentinel-extinguish-silent",
     'echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- часовой формы вывода tweakcc погашен',
     'true "', "N26"),
    # --- крестики слоя накладок ---------------------------------------------
    ("N33-prompt-cross-door-off",
     'if (( __pfail > 0 )); then\n    echo "FATAL: накладки промтов tweakcc объявлены НЕ ЛЕГШИМИ',
     'if false; then\n    echo "FATAL: накладки промтов tweakcc объявлены НЕ ЛЕГШИМИ', "N33"),
    # Считать обязан слой НАКЛАДОК: спутанный слой нашёл бы крестики кода, и
    # обвал слоя накладок остался бы неназванным при том же ненулевом счёте.
    ("N33-prompt-cross-reads-code-layer",
     '__tw_layer_names "$1" prompt \'✗\' | LC_ALL=C grep',
     '__tw_layer_names "$1" code \'✗\' | LC_ALL=C grep', "N33"),
    ("N34-prompt-cross-extinguish-silent",
     'echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь непрошедших накладок tweakcc погашена',
     'true "', "N34"),
    # --- инертные правки: ⊘ и ≡ поимённо ------------------------------------
    # NOTE обязан нести ИЗМЕРЕННЫЕ числа: константа делает расклад нечитаемым
    # ровно там, где он единственный свидетель.
    ("N35-inert-counts-not-reported",
     "конфигурацией $__off, пропущено по версии $__vskip_n",
     "конфигурацией $__off, пропущено по версии 0", "N35"),
    ("N36-inert-extinguish-silent",
     'echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь инертных правок tweakcc погашена',
     'true "', "N36"),
    # Сторона «измерено, но не объявлено»: без неё пропажа проходит молча.
    ("N37-inert-missing-side-off",
     'if [[ -n "$__miss" ]]; then', "if false; then", "N37"),
    # Сторона «объявлено, но не измерено» -- та самая бессрочная индульгенция:
    # вернувшаяся поддержка апстрима оставила бы запись жить дальше.
    # Сторона «объявлено, но не измерено» снимается ЦЕЛИКОМ -- вместе со всеми
    # тремя причинами: ранний возврат до их разбора и есть её отсутствие.
    # Якорь берётся С КОММЕНТАРИЕМ следом: то же условие стоит и внутри
    # ослабления знака ≡, и голое условие совпало бы дважды.
    ("N38-inert-extra-side-off",
     '[[ -n "$__extra" ]] || return 0\n  # ВЛАДЕЛЕЦ ЗНАКА РЕШАЕТ',
     "return 0\n  # ВЛАДЕЛЕЦ ЗНАКА РЕШАЕТ", "N38"),
    # Класс знака и есть предмет: отдай сверке ≡ измерение ⊘ -- и холостой ход
    # снова станет неотличим от пропуска по версии.
    ("N39-inert-noop-reads-vskip",
     '"$__noop" "$(__tw_inert_declared "$__ver" \'≡\')"',
     '"$__vskip" "$(__tw_inert_declared "$__ver" \'≡\')"', "N39"),
    # Второй знак вовсе не сверяется: одна сверка на оба приняла бы ⊘, ушедшее
    # в ≡, за сходимость.
    ("N40-inert-second-sign-unchecked",
     '__tw_inert_check_sign "$__ver" \'≡\'', 'true "$__ver" \'≡\'', "N40"),
    # Объявление ЧИТАЕТСЯ БЕЗ ЗНАКА: имя, объявленное под другим знаком, сошлось
    # бы с любым -- ровно та подмена состава, которую дверь на числе пропускала.
    ("N41-inert-sign-ignored",
     'if (k==v && m==s && nm!="") print nm', 'if (k==v && nm!="") print nm', "N41"),
    ("N42-inert-duplicate-ok", 'if [[ -n "$__inert_dups" ]]; then', "if false; then", "N42"),
    ("N43-inert-why-not-required",
     'if [[ -n "$__inert_nowhy" ]]; then', "if false; then", "N43"),
    # Заглушка совета -- то же утверждение без причины: пустоты мало, её надо
    # ловить ДОСЛОВНО, иначе строку можно вклеить, не написав ни слова.
    ("N44-inert-placeholder-accepted",
     '$3 == "" || $3 == "<причина>" || $3 == "<причина/происхождение>"',
     '$3 == ""', "N44"),
    ("N45-sentinel-blind-to-signs",
     "      if ((cur in want) && index(marks, mark) > 0) next\n      print",
     "      if ((cur in want) && index(marks, mark) >= 0) next\n      print", "N45"),
    # --- пол: две ветки совета ----------------------------------------------
    ("N46-floor-advice-swapped", "if (( __floor_rows == 0 )); then", "if false; then", "N46"),
    ("N47-floor-empty-field-misadvised",
     "if (( __floor_rows == 0 )); then", "if true; then", "N47"),
    # --- пол: происхождение числа -------------------------------------------
    ("N48-floor-why-not-required",
     'if [[ -z "$__floor_why" || "$__floor_why" == "<причина/происхождение числа>" ]]; then',
     "if false; then", "N48"),
    # Заглушка совета -- то же число без причины: пустоты мало, её надо ловить
    # ДОСЛОВНО, иначе строку можно вклеить, не написав ни слова.
    ("N49-floor-placeholder-accepted",
     'if [[ -z "$__floor_why" || "$__floor_why" == "<причина/происхождение числа>" ]]; then',
     'if [[ -z "$__floor_why" ]]; then', "N49"),
    # --- BOM файла кита ------------------------------------------------------
    ("N50-kit-rows-bom-kept",
     '__rows="$(LC_ALL=C sed $\'1s/^\\xef\\xbb\\xbf//\' "$TWEAKCC_EXPECTED_APPLIED"',
     '__rows="$(LC_ALL=C cat "$TWEAKCC_EXPECTED_APPLIED"', "N50"),
    ("N51-kit-value-bom-kept",
     '__want_tried="$(LC_ALL=C sed $\'1s/^\\xef\\xbb\\xbf//\' "$TWEAKCC_EXPECTED_APPLIED"',
     '__want_tried="$(LC_ALL=C cat "$TWEAKCC_EXPECTED_APPLIED"', "N51"),
    # Ограничение области снято: читатель берёт ВЕСЬ вход, и предапплайный
    # список плана снова попадает часовому -- отказ на здоровом прогоне.
    ("N52-scope-unbounded",
     '    !inres { next }\n'
     '    /^  [^ ].*:$/ { cur = $0; sub(/^  /, "", cur); sub(/:$/, "", cur); next }\n'
     '    $0 ~ linere {\n'
     '      mark = $0; sub(/^    /, "", mark); sub(/ .*$/, "", mark)\n'
     '      if ((cur in want) && index(marks, mark) > 0) next\n'
     '      print',
     '    /^  [^ ].*:$/ { cur = $0; sub(/^  /, "", cur); sub(/:$/, "", cur); next }\n'
     '    $0 ~ linere {\n'
     '      mark = $0; sub(/^    /, "", mark); sub(/ .*$/, "", mark)\n'
     '      if ((cur in want) && index(marks, mark) > 0) next\n'
     '      print', "N52"),
    # --- единственность якоря -----------------------------------------------
    # Без двери ноль якорей даёт ПУСТУЮ область: все счёта врут нулём, и отказ
    # приходит от чужой двери, обвиняя реестр форка.
    ("N53-anchor-door-off",
     'if (( __n != 1 )); then\n    echo "FATAL: якорь блока',
     'if false; then\n    echo "FATAL: якорь блока', "N53"),
    # Односторонняя дверь: два прогона в одном выводе прошли бы молча.
    ("N54-anchor-made-one-sided",
     'if (( __n != 1 )); then\n    echo "FATAL: якорь блока',
     'if (( __n < 1 )); then\n    echo "FATAL: якорь блока', "N54"),
    ("N55-anchor-extinguish-silent",
     'echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь якоря блока результатов tweakcc погашена',
     'true "', "N55"),
    # --- инертные: строк под версию нет вовсе -------------------------------
    # Пустое объявление при пустом измерении -- СХОДИМОСТЬ. Сделай её отказом --
    # и покраснеет версия, на которой ничего не сломано.
    ("N56-inert-empty-declaration-refuses",
     'if [[ -z "$__vskip" && -z "$__noop" ]]; then', "if false; then", "N56"),
    # Обратная сторона: измеренные инертные при пустом объявлении обязаны
    # ОТКАЗАТЬ, а не сойтись.
    ("N57-inert-measured-without-rows-ok",
     'if [[ -z "$__vskip" && -z "$__noop" ]]; then', "if true; then", "N57"),
    ("N58-inert-bom-kept",
     '__tw_inert_declared() {\n  LC_ALL=C sed $\'1s/^\\xef\\xbb\\xbf//\'',
     '__tw_inert_declared() {\n  LC_ALL=C cat', "N58"),
    # Голос двери на успехе: снять его -- и сходимость снова станет молчанием.
    ("N59-inert-agreement-silent",
     'echo "NOTE: инертные правки tweakcc на $__ver сошлись с объявлением:', 'true "', "N59"),
    # Вернуть слепой ветви условие: на прогоне, где гасить было нечего, дверь
    # снова замолчит -- и поле вердикта свипа станет нулём на законном прогоне.
    ("N60-inert-extinguish-conditional",
     '    echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь инертных правок tweakcc погашена',
     '    [[ -z "${__noop}${__vskip}" ]] || echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь инертных правок tweakcc погашена',
     "N60"),
    # --- владелец знака ≡ -----------------------------------------------------
    # Послабление на исход ○ -- ПИН: сними его, и штатное действие оператора
    # (выключенный тумблер) снова станет отказом сборки, а лечение, которое
    # отказ советует, сломает машину с включённым тумблером.
    ("N61-noop-extra-unconditional",
     '    __extra="$(__tw_names_minus "$__extra" "$(__tw_off_code_names "$__out")")"',
     '    :', "N61"),
    # Причина «вернулась к жизни» -- своя ветка: без неё измеренная галочка
    # уходит в тишину, и объявление инертности переживает свою причину.
    ("N62-inert-alive-side-off", 'if [[ -n "$__alive" ]]; then', "if false; then", "N62"),
    # Причина «ушла из реестра форка» -- своя ветка, и лечение у неё другое.
    ("N63-inert-gone-side-off", 'if [[ -n "$__gone" ]]; then', "if false; then", "N63"),
    # --- голоса часового формы и двери накладок ------------------------------
    ("N64-form-voice-silent",
     'echo "NOTE: часовой формы строк tweakcc на $__ver: строк вне известных секций',
     'true "', "N64"),
    ("N64-pfail-voice-silent",
     'echo "NOTE: накладки промтов tweakcc на $__ver: объявленных не легшими',
     'true "', "N64"),
    # Вернуть условность слепым NOTE: на прогоне, где гасить было нечего, дверь
    # снова замолчит -- и поле вердикта свипа станет нулём на законном прогоне.
    ("N65-form-extinguish-conditional",
     '    echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- часовой формы вывода tweakcc погашен',
     '    [[ -z "$__unsect" ]] || echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- часовой формы вывода tweakcc погашен',
     "N65"),
    ("N65-pfail-extinguish-conditional",
     '    echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь непрошедших накладок tweakcc погашена',
     '    (( __pfail == 0 )) || echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь непрошедших накладок tweakcc погашена',
     "N65"),
    # --- форма строки правки --------------------------------------------------
    # Верни требование байта вне ASCII -- и знак ИЗ ASCII снова не увидит никто:
    # ни счёта, ни часовой, а первой скажет дверь уровня о чужом предмете.
    ("N66-line-re-nonascii-only",
     "__TW_LINE_RE='^    [^ ][\\200-\\277]* '",
     "__TW_LINE_RE='^    [\\200-\\377][\\200-\\377]* '", "N66"),
    # --- дверь непрошедших накладок ------------------------------------------
    # Отказ обязан НАЗВАТЬ накладки: без перечня оператор узнаёт число и не
    # узнаёт, что именно форк объявил непрошедшим.
    ("N67-prompt-cross-names-dropped",
     '__tw_layer_names "$__out" prompt \'✗\' | LC_ALL=C sed -n \'1,10s/^/  ✗ /p\' >&2 || true',
     'true >&2 || true', "N67"),
    # --- область блока результатов у считающего читателя ---------------------
    ("N68-scope-unbounded-in-names",
     '    !inres { next }\n    # Заголовок секции',
     '    # Заголовок секции', "N68"),
    # --- объявленный уровень ноль --------------------------------------------
    ("N69-zero-level-accepted", 'if (( __want_tried == 0 )); then', "if false; then", "N69"),
    ("N70-zero-advice-ready-row",
     'if (( __rows == 0 && __tried == 0 )); then', "if false; then", "N70"),
    # --- строка объявления инертных без имени --------------------------------
    ("N71-inert-empty-name-ok",
     'if [[ -n "$__inert_noname" ]]; then', "if false; then", "N71"),
    # --- дверь читаемости вывода ---------------------------------------------
    # Верни сырой набор знаков -- и версия, где всё ○/⊘/≡, снова объявляется
    # непрочитанной, хотя разобрана полностью.
    ("N72-result-rows-ticks-only",
     '{ __tw_layer_names "$1" code "$TW_MARKS"; __tw_layer_names "$1" prompt "$TW_MARKS"; }',
     '{ __tw_layer_names "$1" code \'✓✗\'; __tw_layer_names "$1" prompt \'✓✗\'; }', "N72"),
    ("N73-result-rows-extinguish-silent",
     'echo "NOTE: CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 -- дверь читаемости вывода tweakcc погашена',
     'true "', "N73"),
    # --- послабление принадлежит ТОЛЬКО знаку ≡ -------------------------------
    # Раздай его обоим знакам -- и ⊘, объявленный на выключенной конфигом
    # правке, замолчит: знак, которым владеет пара «версия + реестр форка»,
    # начнёт зависеть от конфига чужой машины.
    ("N74-vskip-weakened-too",
     'if [[ "$__s" == \'≡\' ]]; then', "if true; then", "N74"),
    # --- отметка происхождения дома ------------------------------------------
    # Снять ЧТЕНИЕ отметки -- и дом, созданный прогоном, снова получает прежний
    # отказ: свежая машина краснеет без единого дефекта.
    ("N75-origin-not-read",
     'if [[ -s "$TWEAKCC_HOME_ORIGIN" ]]; then', "if false; then", "N75"),
    # Сделать послабление БЕЗУСЛОВНЫМ -- и дом с оператором перестаёт объявлять
    # своё множество: дверь остаётся односторонней навсегда.
    ("N76-origin-relaxation-unconditional",
     'if [[ -s "$TWEAKCC_HOME_ORIGIN" ]]; then', "if true; then", "N76"),
    # Спросить о СУЩЕСТВОВАНИИ вместо непустоты -- и ключом к послаблению
    # становится пустой файл, который ничего не утверждает.
    ("N77-origin-emptiness-ignored",
     'if [[ -s "$TWEAKCC_HOME_ORIGIN" ]]; then',
     'if [[ -f "$TWEAKCC_HOME_ORIGIN" ]]; then', "N77"),
]

# ПРИЧИНА покраснения -- по одной на мутацию, приём корпусного стенда
# (tools/corpus-tools-bench.sh, MUT_CAUSE). Без неё зуб доказывает чужое
# правило: сценарий краснеет и от отказа СОСЕДНЕЙ двери, и от упавшего прибора,
# и беззубость от исправности не отличить -- измерено до этой волны: 3 мутации
# из 65 краснели не своей дверью (docnum:historical).
#
# Где мутант краснеет соседней ВЕТКОЙ своей двери умышленно (снятая ветка
# совета роняет значение в числовой страж; снятая дверь якоря пускает считать
# пустую область), причина называет обе стороны подмены -- что появилось и что
# исчезло, -- и умысел записан, а не подразумевается.
#
# Ключ -- ИМЯ мутации, а не позиция: параллельная таблица разъезжается на
# первой же вставке в середину, и мутация тихо получает чужую причину.
CAUSE = {
    "N1-cross-counted": "кода 15, промтов 21",
    "N1-tried-counts-only-ticks": "объявлено попыток 15, пробовалось 14",
    "N1-agreement-silent": "нет: NOTE: уровень tweakcc на",
    "N2-low-door-off": "нет: слой кода tweakcc просел",
    "N3-high-door-off": "нет: кода пробовалось БОЛЬШЕ объявленного",
    "N3-code-swallows-prompts": "объявлено 15, пробовалось 41",
    "N4-missing-row-unadvised": ("не число: «»", "нет: уровень tweakcc не объявлен"),
    "N5-version-filter-off": ("нет: уровень tweakcc не объявлен", "сошёлся: код 15 попыток"),
    "N6-blind-knob-silent": "нет: дверь уровня tweakcc погашена",
    "N7-prompt-floor-off": "нет: слой промтов tweakcc просел",
    "N8-floor-made-two-sided": "пол 21, легло 30",
    "N9-nolayer-door-off": "нет: слой промтов объявлен отсутствующим, но он ожил",
    "N10-nolayer-refuses-zero": "но он ожил: легло 0, не найдено 0, не легло 0",
    "N11-notfound-silent": "нет: NOTE: накладок промтов не нашлось в образе",
    "N12-floor-validation-off": "нет: не число и не «нет-слоя»",
    "N13-key-trim-off": ("уровень tweakcc не объявлен", "в файле ЕСТЬ, но поле кода в ней пусто"),
    "N14-duplicate-door-off": "нет: приходится строк: 2",
    "N15-empty-field-misadvised": "Строка ниже -- ровно в том виде",
    "N16-off-agreement-silent": "нет: NOTE: выключенные конфигурацией правки tweakcc на",
    "N17-missing-decl-unnamed": ("выключились правки tweakcc, не объявленные выключенными",
                                 "нет: FATAL: объявление выключенных правок tweakcc для дома"),
    "N18-undeclared-off-ok": "нет: выключились правки tweakcc, не объявленные выключенными",
    "N19-stale-decl-ok": "нет: а пробуются:",
    "N20-refuses-after-first-block": ("выключились правки tweakcc, не объявленные выключенными",
                                      "нет: а пробуются:"),
    "N21-decl-not-trimmed": "выключились правки tweakcc, не объявленные выключенными",
    "N22-off-blind-silent": "нет: дверь выключенных правок tweakcc погашена",
    "N23-off-swallows-overlays": "○ patch o9",
    "N24-sentinel-not-consulted": ("нет: не принадлежащие ни одному счёту",
                                   "строк вне известных секций 1"),
    "N25-sentinel-blind": ("нет: не принадлежащие ни одному счёту",
                           "строк вне известных секций 0"),
    "N27-empty-set-refuses": "FATAL: объявление выключенных правок tweakcc для дома",
    "N28-off-bom-kept": "выключились правки tweakcc, не объявленные выключенными",
    "N29-floor-zero-refuses": "FATAL: пол слоя промтов tweakcc для дома",
    "N30-floor-missing-unnamed": "нет: FATAL: пол слоя промтов tweakcc для дома",
    "N31-floor-duplicate-ok": "нет: приходится строк: 2",
    "N32-floor-bom-kept": "пол слоя промтов не объявлен, а измерено",
    "N26-blind-knob-falls-through": "FATAL: строки правок tweakcc, не принадлежащие ни одному счёту",
    "N26-sentinel-extinguish-silent": "нет: часовой формы вывода tweakcc погашен",
    "N33-prompt-cross-door-off": ("нет: накладки промтов tweakcc объявлены НЕ ЛЕГШИМИ",
                                  "объявленных не легшими 2"),
    "N33-prompt-cross-reads-code-layer": "накладки промтов tweakcc объявлены НЕ ЛЕГШИМИ: 1",
    "N34-prompt-cross-extinguish-silent": "нет: дверь непрошедших накладок tweakcc погашена",
    "N35-inert-counts-not-reported": "выключено конфигурацией 0, пропущено по версии 0, вхолостую 1",
    "N36-inert-extinguish-silent": "нет: дверь инертных правок tweakcc погашена",
    "N37-inert-missing-side-off": "нет: которых нет в объявлении",
    "N38-inert-extra-side-off": "нет: которых нет в реестре форка",
    "N39-inert-noop-reads-vskip": "≡ patch v0",
    "N40-inert-second-sign-unchecked": "нет: «отработало вхолостую», которых нет в реестре форка",
    "N41-inert-sign-ignored": "«пропущено по версии», а измерены под другим знаком",
    "N42-inert-duplicate-ok": "нет: пара «знак + имя» объявлена дважды",
    "N43-inert-why-not-required": "нет: есть строки без названной причины",
    "N44-inert-placeholder-accepted": "нет: есть строки без названной причины",
    "N45-sentinel-blind-to-signs": ("нет: не принадлежащие ни одному счёту",
                                    "строк вне известных секций 0"),
    "N46-floor-advice-swapped": "поле пола в ней пусто",
    "N47-floor-empty-field-misadvised": "Взгляните на число один раз",
    "N48-floor-why-not-required": "нет: не называет ПРОИСХОЖДЕНИЕ числа",
    "N49-floor-placeholder-accepted": "нет: не называет ПРОИСХОЖДЕНИЕ числа",
    "N50-kit-rows-bom-kept": "нет: приходится строк: 2",
    "N51-kit-value-bom-kept": "уровень tweakcc не объявлен, а измерено: попыток 15",
    "N52-scope-unbounded": ("не принадлежащие ни одному счёту", "• Verbose property"),
    "N53-anchor-door-off": ("could not read tweakcc's apply output",
                            "нет: якорь блока результатов tweakcc встречается"),
    "N54-anchor-made-one-sided": "нет: якорь блока результатов tweakcc встречается",
    "N55-anchor-extinguish-silent": "нет: дверь якоря блока результатов tweakcc погашена",
    "N56-inert-empty-declaration-refuses": "инертные правки tweakcc не объявлены, а измерены: ⊘ 0, ≡ 0",
    "N57-inert-measured-without-rows-ok": "нет: инертные правки tweakcc не объявлены, а измерены",
    "N58-inert-bom-kept": "«пропущено по версии», которых нет в объявлении",
    "N59-inert-agreement-silent": "нет: NOTE: инертные правки tweakcc на",
    "N60-inert-extinguish-conditional": "нет: дверь инертных правок tweakcc погашена",
    "N61-noop-extra-unconditional": "«отработало вхолостую», а измерены под другим знаком",
    "N62-inert-alive-side-off": "нет: а они снова работают",
    "N63-inert-gone-side-off": "нет: «отработало вхолостую», которых нет в реестре форка",
    "N64-form-voice-silent": "нет: NOTE: часовой формы строк tweakcc на",
    "N64-pfail-voice-silent": "нет: NOTE: накладки промтов tweakcc на",
    "N65-form-extinguish-conditional": "нет: часовой формы вывода tweakcc погашен",
    "N65-pfail-extinguish-conditional": "нет: дверь непрошедших накладок tweakcc погашена",
    "N66-line-re-nonascii-only": ("нет: не принадлежащие ни одному счёту",
                                  "строк вне известных секций 0"),
    "N67-prompt-cross-names-dropped": "нет: overlay p0",
    "N68-scope-unbounded-in-names": "объявлено 15, пробовалось 16",
    "N69-zero-level-accepted": ("нет: объявленный уровень кода для", "сошёлся: код 0 попыток"),
    "N70-zero-advice-ready-row": "%s\t0\t" % VER,
    "N71-inert-empty-name-ok": "нет: есть строки без ИМЕНИ правки",
    "N72-result-rows-ticks-only": "could not read tweakcc's apply output",
    "N73-result-rows-extinguish-silent": "нет: дверь читаемости вывода tweakcc погашена",
    "N74-vskip-weakened-too": "нет: «пропущено по версии», а измерены под другим знаком",
    "N75-origin-not-read": "FATAL: объявление выключенных правок tweakcc для дома",
    "N76-origin-relaxation-unconditional":
        ("создан прогоном, а не оператором",
         "нет: FATAL: объявление выключенных правок tweakcc для дома"),
    "N77-origin-emptiness-ignored":
        ("создан прогоном, а не оператором",
         "нет: FATAL: объявление выключенных правок tweakcc для дома"),
}
missing_cause = [m[0] for m in mutations if m[0] not in CAUSE]
if missing_cause:
    print("  FAIL   N: мутации без объявленной причины покраснения: %s"
          % ", ".join(missing_cause))
    raise SystemExit(4)

if len(ORDER) != declared_s or len(mutations) != declared_m:
    print("  FAIL   N: таблица разошлась с объявленным вкладом -- сценариев %d/%d, мутаций %d/%d"
          % (len(ORDER), declared_s, len(mutations), declared_m))
    raise SystemExit(4)

# ДОМ ПРОВЕРКИ ПРИЧИН -- ОДИН на оба случая, объявляющих причины. Случай (m)
# берёт этот текст ОТСЮДА по меткам ниже и исполняет его у себя: вторая
# редакция этих двенадцати строк разошлась бы с первой на первой же правке, и
# разошлась бы МОЛЧА -- сломанная проверка причин выглядит ровно как проверка,
# которая прошла. Метки -- границы вырезки, и они обязаны стоять в столбце 0.
#
# След -- это «rc=<код> :: <stderr>», и причина ищется в нём подстрокой. У
# мутации, снимающей ГОЛОС, присутствием след не записать: её след -- молчание,
# а «rc=0» сошлось бы с любым зелёным мутантом, то есть не назвало бы ничего.
# Потому вторая форма: приставка «нет: » требует ОТСУТСТВИЯ строки у мутанта И
# её присутствия в следе ЗДОРОВОГО прогона того же сценария. Вторая половина
# обязательна: переименованная строка двери сделала бы отсутствие вечно
# истинным, и зуб перестал бы что-либо доказывать молча.
# CAUSE-HOME-BEGIN
ABSENT = "нет: "


def cause_evidence(result):
    return "rc=%s :: %s" % (result.returncode, result.stderr)


def cause_verdict(cause, evidence, base_evidence):
    """Пусто -- след совпал с объявленной причиной; иначе объяснение."""
    for item in (cause if isinstance(cause, tuple) else (cause,)):
        if item.startswith(ABSENT):
            gone = item[len(ABSENT):]
            if gone not in base_evidence:
                return ("объявлено отсутствие «%s», но этой строки нет и в следе"
                        " ЗДОРОВОГО прогона -- объявление устарело" % gone)
            if gone in evidence:
                return "строка «%s» осталась в следе мутанта" % gone
        elif item not in evidence:
            return "нет следа «%s»" % item
    return ""
# CAUSE-HOME-END


def unpack(name):
    """Сценарий -- кортеж переменной длины: столбец объявления пропущенных по
    версии добавлен волной 39c, отметка происхождения дома -- волной 39d, и
    запись без них означает сходящееся объявление и дом без отметки. Разбор
    ОДИН на прогон и на мутации: два места распаковки разошлись бы на первой же
    новой колонке."""
    row = SCEN[name]
    table, out_text, marker, blind, off_decl, floor = row[:6]
    vskip = row[6] if len(row) > 7 else None
    origin = row[7] if len(row) > 8 else None
    return table, out_text, marker, blind, off_decl, floor, vskip, origin, row[-1]


failed = 0
# След здорового прогона нужен объявлениям отсутствия ниже, и берётся он
# ОТСЮДА: второй прогон того же сценария ради причины удвоил бы стенд.
base_evidence = {}
for name in ORDER:
    table, out_text, marker, blind, off_decl, floor, vskip, origin, predicate = unpack(name)
    result = run(function, table, out_text, marker, blind, off_decl, floor, vskip, origin)
    base_evidence[name] = cause_evidence(result)
    if predicate(result):
        print("  ok     %s" % name)
    else:
        failed += 1
        print("  FAIL   %s rc=%s stderr=%r" % (name, result.returncode, result.stderr))

for mutation, old, new, owner in mutations:
    if function.count(old) != 1:
        failed += 1
        print("  FAIL   mutation %s anchor count=%s" % (mutation, function.count(old)))
        continue
    table, out_text, marker, blind, off_decl, floor, vskip, origin, predicate = unpack(owner)
    result = run(function.replace(old, new, 1), table, out_text, marker, blind, off_decl,
                 floor, vskip, origin)
    evidence = cause_evidence(result)
    why = cause_verdict(CAUSE[mutation], evidence, base_evidence[owner])
    if predicate(result):
        failed += 1
        print("  FAIL   mutation %s did not redden %s" % (mutation, owner))
    elif why:
        failed += 1
        print("  FAIL   mutation %s покраснила %s ЧУЖОЙ причиной: %s" % (mutation, owner, why))
        print("         объявлено: %r, было: %s"
              % (CAUSE[mutation], evidence.replace("\n", "|")[:300]))
    else:
        print("  RED    mutation %s (%s)" % (mutation, owner))

print("build-path-probe N: case held and its controls showed teeth")
raise SystemExit(1 if failed else 0)
PY_LEVEL
}

if [[ "$CASES" == *n* ]]; then
  case_n || exit $?
  CASES="${CASES//n/}"
  if [[ -z "$CASES" ]]; then
    echo "build path ($ALL_CASES): every assertion held, and the control shows they have teeth"
    exit 0
  fi
fi

if [[ "$CASES" == *m* ]]; then
  case_m || exit $?
  CASES="${CASES//m/}"
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
# --- killed-predecessor config guard ----------------------------------------
PROBE_LIVE_CFG_VER="$(python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1], encoding="utf-8")).get("ccVersion")
except Exception:
    v = None
print(v if isinstance(v, str) else "")' "$TWEAKCC_CFG" 2>/dev/null || true)"
if [[ "$PROBE_LIVE_CFG_VER" == "$TWEAKCC_PROBE_CFG_MARKER" ]]; then
  echo "build-path-probe: ОТКАЗ -- ccVersion is the build-path probe marker '$TWEAKCC_PROBE_CFG_MARKER'." >&2
  echo "  This marker has two possible meanings:" >&2
  echo "    * a previous probe died under SIGKILL; SIGKILL does not run the probe's trap," >&2
  echo "      and its snapshots, if any, are under:" >&2
  echo "        ${TMPDIR:-/tmp}/cc-build-path-probe.*/config.json.snapshot" >&2
  echo "    * another build-path probe may be running now and borrowing this config." >&2
  echo "      Check for: bash .../tools/build-path-probe.sh" >&2
  echo "      If that process is alive, wait for it to finish; do not repair its loan." >&2
  echo "  Only you know which of the two is the truth:" >&2
  echo "    * for a dead predecessor, restore config.json.snapshot by hand, or write" >&2
  echo "      the real Claude Code version as ccVersion if you know it;" >&2
  echo "    * for a live probe, wait for it to finish and restore its own snapshot." >&2
  exit 2
fi
# --- end killed-predecessor config guard ------------------------------------
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
  python3 - "$TWEAKCC_CFG" "$TWEAKCC_PROBE_CFG_MARKER" <<'PY'
import json, os, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg['ccVersion'] = sys.argv[2]
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
    # Объявленный заём: ccVersion с probe-marker записал ЭТОТ зонд, а не
    # посторонний процесс; страж конвейера пропускает только этот названный вход.
    # Объявленный пропуск: каждая сборка зонда идёт без sync цен, и это
    # снятое покрытие (раунд 18, G-1). Обе уступки печатаются в логе, а не
    # остаются молчаливыми.
    # Пропуск стендов КИТА -- не экономия, а владелец предмета: их предмет сам
    # кит (инструменты судьи, цены, синхронизация проб, перепись и зубы гейта
    # чисел), он один и тот же во всех проходах зонда, а зонд меряет ВЕТКУ
    # СБОРКИ. Замерено 06.09 на 2.1.261: проход со стендами 687 с, без них
    # 170 с; шесть проходов повторяли один замер шестикратно и держали свип
    # 44 минуты из 73. Батарею гоняет сам свип, один раз (отметка .bench-ran).
    # Ручка стоит в ПРЕФИКСЕ команды, а не в списке снятия люков выше: тот
    # список обрывается комментарием и становится строкой одних присваиваний,
    # а из неё переменная, которой не было в окружении, до конвейера не едет.
    CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
    CLAUDE_PATCH_PROBE_CFG_LOAN=1 CLAUDE_PATCH_SKIP_MODELS=1 \
      bash "$1" "${@:4}" ) >"$3" 2>&1
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
# Объявление стоит ЗДЕСЬ, а не только в логах проходов: их каталог зонд
# стирает за собой, и уступка исчезла бы вместе с ним.
echo "build-path-probe: во ВСЕХ случаях сборки стенды кита пропущены (CLAUDE_PATCH_SKIP_KIT_BENCH=1) -- их предмет кит, а не ветка сборки; батарею гоняет свип один раз"
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
  if [[ "$ALL_CASES" == *c* || "$ALL_CASES" == *d* || "$ALL_CASES" == *u* || "$ALL_CASES" == *x* || "$ALL_CASES" == *r* || "$ALL_CASES" == *p* || "$ALL_CASES" == *l* || "$ALL_CASES" == *k* || "$ALL_CASES" == *m* ]]; then
    echo "build path ($ALL_CASES): every assertion held, and the control shows they have teeth"
  else
    echo "build path ($ALL_CASES): every assertion held; НИ ОДИН контроль (c/d/u/x/r/p/l/k/m) не гонялся -- зубы не доказаны"
  fi
else
  echo "build path: $FAILED assertion(s) failed; logs under $ROOT (kept)" >&2
  KEEP_ROOT=1
  echo "build-path-probe: KEEP_ROOT=1 -- корень $ROOT оставлен для разбора" >&2
  exit 1
fi
