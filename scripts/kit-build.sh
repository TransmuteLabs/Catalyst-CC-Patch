#!/usr/bin/env bash
# Building the patch kit FROM THE LIVE FILES.
#
# This exists because the kit was twice built by unpacking the PREVIOUS
# archive with edits made in place: the only home of the README and the spec
# was the archive itself, and both fell behind unnoticed (the README spoke of
# 25 checks when there were 34 — docnum:historical). Every file now lives on
# disk, and the archive is a derivative.
# Exit codes -- the kit's shared table (see the top of claude-patch-all.sh):
#   0  the kit is assembled
#   1  assembly refused: a required file is missing or a gate of the build said no
# Death by signal is answered as 128+N (130 INT, 143 TERM, via the split
# traps) and is NOT a kit verdict (round 28, F-8).
# 130 arrives when INT is delivered to the process GROUP (what a terminal does
# on Ctrl-C); `kill -INT <script pid>` while a foreground child is alive is
# dropped by bash -- the child runs to completion, the trap does NOT fire, and
# the run finishes with its ordinary code. Nothing is truncated, so that code
# is honest; but probing 130 with a single-pid kill yields the false
# conclusion "the trap is broken" (measured, round 25, F-6).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The version is taken from the INSTALLED image, not from a default in the
# script: a hardcoded default fell a version behind and silently glued a
# foreign label onto the kit — exactly the same class as a false number in the
# transcript marker.
VER="${1:-}"
if [ -z "$VER" ]; then
  VER="$(ls -1 "$HOME/.local/share/claude/versions" 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
fi
[ -n "$VER" ] || { echo "не удалось определить версию; передайте её первым доводом" >&2; exit 1; }
STAMP="$(date +%Y%m%d)"
NAME="claude-patch-kit-$VER"
OUT="$ROOT/dist/$NAME-$STAMP.tar.gz"
# The tmp archive name must never outlive a killed build: a tar interrupted
# mid-write left claude-patch-kit-*.tar.gz.tmp.<pid> in dist/ forever — no
# later run removes it (each build rolls its own pid into the name). The trap
# covers every exit route, including set -e failures and signals; rm -f keeps
# successful builds (where the tmp was mv'd away) a no-op.
# Часовой оборванного прогона: bash 3.2 отдаёт код 0, когда скрипт с
# EXIT-трапом умирает на фатальной ошибке ПОДСТАНОВКИ (unbound variable под
# `set -u`, `${x:?}`, bad substitution) -- провал невидим вызывающему
# (измерено 2026-08-28). Штатный конец объявляет себя, трап без объявления
# краснит сам.
__DONE=0
__exit_guard() {
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
  rm -f "$OUT.tmp.$$"
  # Стадия -- полная копия кита в TMPDIR. Прежде её убирал только путь успеха,
  # а каждый отказ и каждый сигнал оставляли её навсегда, без прополки
  # (раунд 19, В-10).
  [[ -n "${STAGE:-}" ]] && rm -rf "$(dirname "$STAGE")"
  if [[ "${__DONE:-0}" != 1 && "$__rc" == 0 ]]; then
    echo "kit-build: ОТКАЗ -- прогон оборвался, не дойдя до конца (ошибка оболочки выше)" >&2
    exit 1
  fi
  exit "$__rc"
}
trap __exit_guard EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
STAGE="$(mktemp -d)/$NAME"
# The judge canon lives in the project; ~/.claude/judge is the DEPLOYMENT.
# The kit is built from the canon: otherwise whatever someone edited on the
# live machine would ride into the archive, and the project would diverge from
# the archive again.
JUDGE="$ROOT/judge"

mkdir -p "$STAGE/judge" "$STAGE/idle-watch" "$STAGE/docs" "$STAGE/tools"

# The kit ROOT is placed by walking the top level, not by a name list — the
# list here had already fallen behind the tree: LICENSE lived in the root and
# never reached the archive, and no door said so. A list living next to its
# home must either be read from the home or not exist.
#
# Exceptions are declared HERE, by name, in ROOT_SKIP; the guard below refuses
# on an exception whose file is gone, because a stale declaration hides exactly
# what a stale list hides. Hidden entries (dotfiles) are outside the glob by
# construction and are not part of the kit.
ROOT_SKIP=""
for f in "$ROOT"/*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  case "$ROOT_SKIP" in *" $b "*) continue;; esac
  cp "$f" "$STAGE/$b"
done
# Documents are placed by ENUMERATING the directory, not by a name list: a
# list falls behind the tree silently. It happened — the new probe registry
# spec did not make it into the kit while the build still succeeded. Task
# briefs (brief-*) do not go into the kit: they are one-off work orders, not a
# description of the mechanism.
#
# Обход НЕрекурсивен намеренно, и обе стороны -- копия и сверка ниже -- обязаны
# остаться такими: docs/review/ это журнал кампании (ledger раундов и отчёты
# аудиторов), а не исходник кита. Он живёт в репозитории ради истории и
# переживания перезагрузки, но в комплект не едет.
for f in "$ROOT/docs"/*.md; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  case "$b" in brief-*) continue;; esac
  cp "$f" "$STAGE/docs/$b"
done
# The NAME list fell behind the tree twice already (the watcher was missing
# from the archive for two days; probes-migrate.py did not make it into the kit
# on the day it appeared). So tools/ is placed by walking the directory, not by
# a list.
for f in "$ROOT/tools"/*; do
  [ -f "$f" ] || continue
  cp "$f" "$STAGE/tools/$(basename "$f")"
done
# The NAME list fell behind the tree a THIRD time: recstore.py and fresh-runs.py
# entered the set on 15.09 and this build refused on 16.09 — the guard below
# caught them, the list did not. judge/ is now placed by WALKING the directory,
# exactly like tools/ above. A list living next to its home must either be read
# from the home or not exist at all.
for f in "$JUDGE"/*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  case "$b" in *.pyc) continue;; esac
  cp "$f" "$STAGE/judge/$b"
done
# judge/bench/ carries the judge tools' own teeth, and it is a SUBDIRECTORY:
# both the copy above and the completeness guard below walk only the top level,
# so the teeth were invisible to either — the same blindness one level down.
# Run records (*.jsonl) are machine data, not source, and stay out.
if [ -d "$JUDGE/bench" ]; then
  mkdir -p "$STAGE/judge/bench"
  for f in "$JUDGE/bench"/*; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in *.jsonl|*.pyc) continue;; esac
    cp "$f" "$STAGE/judge/bench/$b"
  done
fi
# The probes home: one settings file for all probes plus an artifacts
# directory for each.
mkdir -p "$STAGE/probes"
for f in "$ROOT/probes"/*; do
  [ -f "$f" ] && cp "$f" "$STAGE/probes/$(basename "$f")"
  if [ -d "$f" ]; then
    mkdir -p "$STAGE/probes/$(basename "$f")"
    cp "$f"/* "$STAGE/probes/$(basename "$f")/" 2>/dev/null || true
  fi
done
# The fleet idle watcher is the second probe of the same core. It was missing
# from the kit for two days: the recipe lists NAMES, and nobody added the new
# mechanism to the list. A guard below exists so this does not happen silently
# again.
for f in README.md; do
  cp "$ROOT/idle-watch/$f" "$STAGE/idle-watch/$f"
done
# The name was pinned here and then CHANGED (com.maratkarimov ->
# com.transmutelabs, commit 3303d36) without this line following it. Because the
# copy was guarded by `[[ -f ]] &&`, the miss was silent: the kit simply shipped
# without the plist. Glob instead of naming, so a rename cannot outrun this
# line; the judge/ completeness guard below is what finally reported it.
for f in "$ROOT"/judge/*.plist; do
  [ -f "$f" ] || continue
  cp "$f" "$STAGE/judge/$(basename "$f")"
done

# The tools/ completeness guard: walking the directory makes omission
# impossible, but the check must also fail when the walk is swapped back for a
# list.
miss_tools=0
for f in "$ROOT/tools"/*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [ -f "$STAGE/tools/$b" ] || { echo "ОШИБКА: tools/$b живёт на диске, но в комплект не кладётся" >&2; miss_tools=1; }
done
[ "$miss_tools" = 0 ] || exit 1

# The number of checks in the README must match the number of checks in the
# pipeline: that exact divergence was the symptom of the stale documentation.
N="$(sed -n '/^checks = {/,/^}/p' "$ROOT/claude-patch-all.sh" | grep -cE "^    '")"
# The pattern follows the README's LANGUAGE, and that is the trap: while the
# README was Russian the numeral had three inflected forms, a shared stem
# prefix missed one of them, and the gate cried wolf. Translating the README
# to English broke it the other way round — the Russian alternation matched
# nothing at all, so the gate failed on every single build instead. A pattern
# that matches nothing is indistinguishable here from a genuine mismatch, so
# whoever changes the README's language re-checks this line in the same edit.
grep -qE "$N checks?" "$STAGE/README.md" || {
  echo "ОШИБКА: в конвейере $N проверок, README говорит иначе" >&2; exit 1; }

# The completeness guard: every file living in a probe home must either make
# it into the kit or be named in the exceptions HERE. A name list without a
# guard loses new files silently — that is how the watcher fell out of the
# archive.
SKIP=" fixtures "
miss=0
# Каждое ОБЪЯВЛЕННОЕ исключение обязано существовать: объявление, которому
# нечего исключать, прячет ровно то же, что прячет отставший список -- оно
# переживает свой повод и молча снимает сторожа с имени, которое однажды
# вернётся. То же правило уже действует в tools/orphan-stand-gate.py.
for b in $SKIP; do
  [ -e "$ROOT/judge/$b" ] || [ -e "$ROOT/idle-watch/$b" ] || {
    echo "ОШИБКА: исключение '$b' объявлено, а ни в judge/, ни в idle-watch/ его нет -- устаревшее объявление" >&2; miss=1; }
done
for b in $ROOT_SKIP; do
  [ -e "$ROOT/$b" ] || {
    echo "ОШИБКА: исключение корня '$b' объявлено, а файла нет -- устаревшее объявление" >&2; miss=1; }
done
# Ценз полноты КОРНЯ: файл верхнего уровня обязан либо ехать в комплект, либо
# быть названным в ROOT_SKIP. Без этой стороны обход можно молча вернуть к
# списку имён, и всё начнётся сначала.
for f in "$ROOT"/*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  case "$ROOT_SKIP" in *" $b "*) continue;; esac
  [ -f "$STAGE/$b" ] || { echo "ОШИБКА: $b живёт в корне, но в комплект не кладётся" >&2; miss=1; }
done
# The docs directory is checked by the same rule as the probe homes: a file
# on disk missing from the kit is a build error, not a trifle. Without this
# branch the list falling behind the tree was not noticed at all.
for f in "$ROOT/docs"/*.md; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  case "$b" in brief-*) continue;; esac
  [ -f "$STAGE/docs/$b" ] || { echo "ОШИБКА: docs/$b живёт на диске, но в комплект не кладётся" >&2; miss=1; }
done
for home in judge idle-watch; do
  for f in "$ROOT/$home"/*; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    case "$SKIP" in *" $b "*) continue;; esac
    [ -f "$STAGE/$home/$b" ] || { echo "ОШИБКА: $home/$b живёт на диске, но в комплект не кладётся" >&2; miss=1; }
  done
done
# The guard walks the TOP level only, so a file one directory down was outside
# its sight entirely: judge/bench/ (the tools' teeth) could vanish from the kit
# without a word. Run records are machine data and are excluded on both sides —
# the copy above skips them too, so the two rules must not drift apart.
for f in "$ROOT/judge/bench"/*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  case "$b" in *.jsonl|*.pyc) continue;; esac
  [ -f "$STAGE/judge/bench/$b" ] || { echo "ОШИБКА: judge/bench/$b живёт на диске, но в комплект не кладётся" >&2; miss=1; }
done
[ "$miss" = 0 ] || exit 1

# The archive name is dated to the DAY: a second build of the same day wrote
# straight over the finished tarball, and a consumer reading it at that moment
# (unpacking, verifying) received a truncated archive. Write under a temp name
# in the same directory and mv: a rename within one filesystem is atomic, the
# reader always sees a complete archive — either the old one or the new one.
# Обломки от УБИТЫХ прогонов: трап их не видит (SIGKILL), а имя несёт чужой
# pid, и следующая сборка своим `rm -f "$OUT.tmp.$$"` их не трогает -- каждый
# лежал в dist/ навсегда (круг 21, E-9). Ничьим считается только доказанно
# ничей: мёртвый номер. Живой -- соседняя сборка, её файл не наш.
for __stale in "$ROOT"/dist/*.tar.gz.tmp.[0-9]*; do
  [[ -e "$__stale" ]] || continue
  __spid="${__stale##*.}"
  case "$__spid" in ''|*[!0-9]*) continue ;; esac
  kill -0 "$__spid" 2>/dev/null && continue
  rm -f "$__stale" && echo "kit-build: убран обломок убитой сборки: $(basename "$__stale")"
done

tar czf "$OUT.tmp.$$" -C "$(dirname "$STAGE")" "$NAME"
mv -f "$OUT.tmp.$$" "$OUT"
rm -rf "$(dirname "$STAGE")"
echo "$OUT"
__DONE=1   # штатный конец
ls -l "$OUT"
