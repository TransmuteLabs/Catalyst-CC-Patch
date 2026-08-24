#!/usr/bin/env bash
# Сборка комплекта патчей ИЗ ЖИВЫХ ФАЙЛОВ.
#
# Пишется потому, что комплект дважды собирался распаковкой ПРЕДЫДУЩЕГО
# архива с правкой на месте: единственным домом README и спеки был сам архив,
# и обе отстали незаметно (README говорил про 25 проверок, когда их было 34).
# Дом каждого файла теперь на диске, а архив — производная.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Версия берётся у УСТАНОВЛЕННОГО образа, а не из умолчания в скрипте:
# зашитое умолчание отстало на версию и молча клеило на комплект чужой
# ярлык — ровно тот класс, что и лживое число в маркере ленты.
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
# Канон судьи — в проекте, дом ~/.claude/judge это РАЗВЁРТЫВАНИЕ.
# Комплект собирается из канона: иначе в архив уедет то, что кто-то
# правил на живой машине, и проект снова разойдётся с архивом.
JUDGE="$ROOT/judge"

mkdir -p "$STAGE/judge" "$STAGE/idle-watch" "$STAGE/docs" "$STAGE/tools"

for f in claude-patch-all.sh tweakcc-patch.js claude_patch.py set-model-costs.py \
         patch-claude-routing.sh patch-claude-routing.ps1 patch_claude_routing.py; do
  cp "$ROOT/$f" "$STAGE/$f"
done
cp "$ROOT/README.md"                        "$STAGE/README.md"
cp "$ROOT/AGENTS.md"                        "$STAGE/AGENTS.md"
# Документы кладутся ПЕРЕЧИСЛЕНИЕМ каталога, а не поимённым списком: список
# молча отстаёт от дерева. Так и вышло — новая спека реестра наблюдателей не
# попала в комплект, а сборка при этом отработала успешно. Брифы задач
# (brief-*) в комплект не идут: это наряды на разовую работу, а не описание
# механизма.
for f in "$ROOT/docs"/*.md; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  case "$b" in brief-*) continue;; esac
  cp "$f" "$STAGE/docs/$b"
done
cp "$ROOT/tools/listener.py"                "$STAGE/tools/listener.py"
cp "$ROOT/tools/probe-bench.js"             "$STAGE/tools/probe-bench.js"
cp "$ROOT/tools/emit-check.js"              "$STAGE/tools/emit-check.js"
for f in config.json prompt.md body.json README.md NOTES.md replay.py compact.py validate.py \
         channel.py adjudicate.py; do
  cp "$JUDGE/$f" "$STAGE/judge/$f"
done
# Наблюдатель за флотом — вторая проба того же ядра. В комплект он не попадал
# двое суток: рецепт перечисляет ИМЕНА, и появившийся механизм в перечень
# никто не дописал. Ниже стоит сторож, чтобы это не повторилось молча.
for f in config.json prompt.md README.md; do
  cp "$ROOT/idle-watch/$f" "$STAGE/idle-watch/$f"
done
PLIST="$ROOT/judge/com.maratkarimov.judge-compact.plist"
[[ -f "$PLIST" ]] && cp "$PLIST" "$STAGE/judge/$(basename "$PLIST")"

# Число проверок в README обязано совпадать с числом проверок в конвейере:
# именно это расхождение и было симптомом отставшей документации.
N="$(sed -n '/^checks = {/,/^}/p' "$ROOT/claude-patch-all.sh" | grep -cE "^    '")"
# Формы числительного разные («35 проверок», «34 проверки») — префикс
# «проверк» не покрывает родительный падеж и давал ложную тревогу.
grep -qE "$N (проверок|проверки|проверка)" "$STAGE/README.md" || {
  echo "ОШИБКА: в конвейере $N проверок, README говорит иначе" >&2; exit 1; }

# Сторож полноты: всякий файл, живущий в доме пробы, обязан либо попасть в
# комплект, либо быть назван в исключениях ЗДЕСЬ. Перечень имён без сторожа
# теряет новое молча — так из архива и выпал наблюдатель.
SKIP=" fixtures "
miss=0
# Каталог docs проверяется по тому же правилу, что и дома проб: файл на диске,
# которого нет в комплекте, — ошибка сборки, а не мелочь. Без этой ветви
# отставание списка от дерева не замечалось вовсе.
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
