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

for f in claude-patch-all.sh tweakcc-patch.js claude_patch.py set-model-costs.py \
         patch-claude-routing.sh patch-claude-routing.ps1 patch_claude_routing.py; do
  cp "$ROOT/$f" "$STAGE/$f"
done
cp "$ROOT/README.md"                        "$STAGE/README.md"
cp "$ROOT/AGENTS.md"                        "$STAGE/AGENTS.md"
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
for f in README.md NOTES.md replay.py compact.py validate.py \
         channel.py adjudicate.py; do
  [ -f "$JUDGE/$f" ] && cp "$JUDGE/$f" "$STAGE/judge/$f"
done
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
