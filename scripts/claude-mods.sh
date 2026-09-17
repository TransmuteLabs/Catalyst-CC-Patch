#!/bin/bash
# Session-only fallback: FUNCTION_HOOKS + CARRIER=mod + one --plugin-dir.
# Primary path: TransmuteLabs/Catalyst plugin catalyst-probes@catalyst
# (settings.json env + enabledPlugins). This script does not write
# settings.json and does not patch the live binary.
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
FAMILY="${CATALYST_FAMILY:-$KIT/../Catalyst}"
PLUGIN="$FAMILY/plugins/catalyst-probes"
if [[ ! -f "$PLUGIN/hooks/register.ts" ]]; then
  PLUGIN="${HOME}/.claude/plugins/cache/catalyst/catalyst-probes/0.1.0"
fi
if [[ ! -f "$PLUGIN/hooks/register.ts" ]]; then
  echo "claude-mods: catalyst-probes not found (clone TransmuteLabs/Catalyst or install catalyst-probes@catalyst)" >&2
  exit 2
fi
pick_image() {
  if [[ -n "${CLAUDE_MODS_IMAGE:-}" ]]; then
    printf '%s\n' "$CLAUDE_MODS_IMAGE"
    return
  fi
  command -v claude
}
# Пустой образ допустим: следующая проверка требует исполняемый путь и называет отказ.
IMG="$(pick_image)" || true
if [[ -z "$IMG" || ! -x "$IMG" ]]; then
  echo "claude-mods: no executable image" >&2
  exit 2
fi
export CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1
# CONSTRAINT: имена ручек носителя здесь НЕ ПЕРЕЧИСЛЯЮТСЯ. Их дом -- вставки
# tweakcc-patch.js: каждая ручка существует ровно потому, что в образ вписан
# сплайс, который её читает, и любой список рядом был бы проекцией этого дома.
# Проекция уже стоила бы молча: четвёртая ручка, добавленная сплайсом, здесь
# осталась бы невыставленной, мод не стал бы носителем своей пробы, а патч
# продолжил бы работать -- расхождение без единого отказа. Форма чтения в доме
# устойчива (сплайс обязан спросить окружение), поэтому перечень берётся
# ОТТУДА. Пустой результат -- НЕ ноль ручек, а смена формы в доме: отказ.
HOME_SRC="$KIT/tweakcc-patch.js"
if [[ ! -f "$HOME_SRC" ]]; then
  echo "claude-mods: нет дома ручек носителя ($HOME_SRC) -- перечень взять неоткуда" >&2
  exit 2
fi
# CONSTRAINT: `|| true` здесь обязателен -- под `set -euo pipefail` код
# командной подстановки становится кодом ПРИСВАИВАНИЯ, и ноль совпадений
# (именно тот случай, который обязан назваться) убил бы скрипт до отказа ниже.
CARRIERS="$(grep -oE 'process\.env\.CLAUDE_[A-Z0-9_]*_CARRIER' "$HOME_SRC" \
            | sed 's/^process\.env\.//' | sort -u || true)"
if [[ -z "$CARRIERS" ]]; then
  echo "claude-mods: в $HOME_SRC не нашлось ни одной ручки носителя -- форма чтения в доме сменилась, перечень недействителен" >&2
  exit 2
fi
for name in $CARRIERS; do
  export "$name=${!name:-mod}"
done
exec "$IMG" --plugin-dir "$PLUGIN" "$@"
