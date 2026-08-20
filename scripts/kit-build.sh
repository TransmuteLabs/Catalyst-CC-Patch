#!/usr/bin/env bash
# Сборка комплекта патчей ИЗ ЖИВЫХ ФАЙЛОВ.
#
# Пишется потому, что комплект дважды собирался распаковкой ПРЕДЫДУЩЕГО
# архива с правкой на месте: единственным домом README и спеки был сам архив,
# и обе отстали незаметно (README говорил про 25 проверок, когда их было 34).
# Дом каждого файла теперь на диске, а архив — производная.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VER="${1:-2.1.237}"
STAMP="$(date +%Y%m%d)"
NAME="claude-patch-kit-$VER"
OUT="$ROOT/dist/$NAME-$STAMP.tar.gz"
STAGE="$(mktemp -d)/$NAME"
# Канон судьи — в проекте, дом ~/.claude/judge это РАЗВЁРТЫВАНИЕ.
# Комплект собирается из канона: иначе в архив уедет то, что кто-то
# правил на живой машине, и проект снова разойдётся с архивом.
JUDGE="$ROOT/judge"

mkdir -p "$STAGE/judge" "$STAGE/docs" "$STAGE/tools"

for f in claude-patch-all.sh tweakcc-patch.js claude_patch.py set-model-costs.py \
         patch-claude-routing.sh patch-claude-routing.ps1 patch_claude_routing.py; do
  cp "$ROOT/$f" "$STAGE/$f"
done
cp "$ROOT/README.md"                        "$STAGE/README.md"
cp "$ROOT/docs/judge-architecture.md"       "$STAGE/docs/judge-architecture.md"
cp "$ROOT/docs/judge-patch-spec.md"         "$STAGE/docs/judge-patch-spec.md"
cp "$ROOT/tools/listener.py"                "$STAGE/tools/listener.py"
for f in config.json prompt.md body.json README.md replay.py compact.py validate.py \
         channel.py adjudicate.py; do
  cp "$JUDGE/$f" "$STAGE/judge/$f"
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

tar czf "$OUT" -C "$(dirname "$STAGE")" "$NAME"
rm -rf "$(dirname "$STAGE")"
echo "$OUT"
ls -l "$OUT"
