#!/usr/bin/env bash
# Building the patch kit FROM THE LIVE FILES.
#
# This exists because the kit was twice built by unpacking the PREVIOUS
# archive with edits made in place: the only home of the README and the spec
# was the archive itself, and both fell behind unnoticed (the README spoke of
# 25 checks when there were 34). Every file now lives on disk, and the archive
# is a derivative.
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
PLIST="$ROOT/judge/com.maratkarimov.judge-compact.plist"
[[ -f "$PLIST" ]] && cp "$PLIST" "$STAGE/judge/$(basename "$PLIST")"

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

tar czf "$OUT" -C "$(dirname "$STAGE")" "$NAME"
rm -rf "$(dirname "$STAGE")"
echo "$OUT"
ls -l "$OUT"
