#!/usr/bin/env bash
# Прогнать ОТГРУЖЕННЫЙ блок проверок по произвольному образу.
#
# Зачем. Проверка принимается только вместе с мутацией, которая её краснит.
# Естественный ход -- мутировать образ и пересобрать -- НЕ РАБОТАЕТ и при этом
# выглядит успешным: tweakcc восстанавливает свой бэкап поверх названной цели
# до всякого патча, мутация входа стирается, сборка даёт `OK=118` и `Done.`
# (измерено 2026-08-27 дважды подряд; отсюда же вырос страж «цель против
# бэкапа»). Правильная форма контроля -- мутировать УЖЕ СОБРАННЫЙ образ и
# прогнать по нему проверки. Это и делает данный инструмент, за секунды и без
# сборки.
#
# Блок проверок не дублируется: он ИЗВЛЕКАЕТСЯ из claude-patch-all.sh по
# якорю. Копия блока рано или поздно разошлась бы с оригиналом и мерила бы не
# то, о чём отчитывается; пропажа якоря -- отказ, а не тишина.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-patch-all.sh"
PATCH_SRC="$HERE/../tweakcc-patch.js"

IMG="${1:-}"
if [[ -z "$IMG" ]]; then
  echo "использование: $(basename "$0") <собранный-образ> [исходник-патча]" >&2
  echo "  пример контроля:" >&2
  echo "    cp built.bin mutant.bin" >&2
  echo "    # мутация РАВНОЙ ДЛИНЫ в mutant.bin" >&2
  echo "    $(basename "$0") mutant.bin   # ждём rc=1 и ровно одну красную" >&2
  exit 2
fi
[[ -f "$IMG" ]] || { echo "нет образа: $IMG" >&2; exit 2; }
[[ -z "${2:-}" ]] || PATCH_SRC="$2"
[[ -f "$PATCH_SRC" ]] || { echo "нет исходника патча: $PATCH_SRC" >&2; exit 2; }

BLOCK="$(mktemp)"
trap 'rm -f "$BLOCK"' EXIT INT TERM

python3 - "$SCRIPT" "$BLOCK" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
lines = open(src, encoding='utf-8').read().split('\n')
marker = 'python3 - "$BIN" "$OUR_PATCH" <<'
start = next((i for i, l in enumerate(lines) if l.startswith(marker)), -1)
if start < 0:
    sys.exit('ЯКОРЬ ПРОПАЛ: блок проверок не найден в ' + src)
end = next((i for i in range(start + 1, len(lines)) if lines[i] == 'PY'), -1)
if end < 0:
    sys.exit('ЯКОРЬ ПРОПАЛ: блок проверок не закрыт')
open(out, 'w', encoding='utf-8').write('\n'.join(lines[start + 1:end]))
# Счёт считается ОТДЕЛЬНОЙ строкой, а не выражением внутри подстановки:
# гейт чисел в доках читает «существительное -- двоеточие -- число», и
# арифметика `{end - start - 1}` подставляла ему в это правило единицу как
# заявленный счёт проверок. Величина здесь -- строки, а не проверки.
extracted_lines = end - start - 1
sys.stderr.write(f'блок проверок извлечён, строк: {extracted_lines}\n')
PY

python3 "$BLOCK" "$IMG" "$PATCH_SRC"
