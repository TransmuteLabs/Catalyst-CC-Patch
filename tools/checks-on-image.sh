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

# Режим пола и подмена кита -- для стенда: чтобы отрицательный контроль мог
# прогнать МУТИРОВАННУЮ копию конвейера, не трогая дерево.
FLOOR=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --floor)  FLOOR=1; shift ;;
    --script) SCRIPT="$2"; shift 2 ;;
    *)        break ;;
  esac
done

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

if [[ $FLOOR -eq 0 ]]; then
  python3 "$BLOCK" "$IMG" "$PATCH_SRC"
  exit $?
fi

# --- режим пола: что остаётся зелёным на ПРИСТИННОМ образе --------------------
#
# Проверка, которую нельзя провалить, выглядит ровно как проверка, которая
# проходит. Одна такая прожила в реестре неизвестно сколько: порог BOM-полосы
# стоял `>= 2`, а стоковые образы несут этот же приём 3-4 раза сами -- то есть
# проверка была зелена на образе, где наших патчей нет вообще, и не увидела бы
# потери всех четырёх наших полос (2026-08-28, находка раунда 17).
#
# Здесь закрывается весь класс: на пристинном образе зелёными имеют право
# остаться РОВНО те проверки, что перечислены в DECLARED ниже, и каждая -- по
# названной там причине (счёт не повторяется здесь словами: список -- его
# единственный дом, а повтор устаревал бы молча). Любая незаявленная зелёная
# означает порог НИЖЕ стокового пола. Пропажа объявленной из списка зелёных --
# тоже находка: значит устарело объявление, и его надо прочитать заново, а не
# подогнать.
python3 - "$BLOCK" "$IMG" "$PATCH_SRC" <<'FLOOR_PY'
import subprocess, sys

block, img, patch_src = sys.argv[1], sys.argv[2], sys.argv[3]
# Объявленные исключения. Каждое -- со своей причиной, и причина проверяема.
DECLARED = {
    # Читают ИСХОДНИК патча (`src`), а не образ: на любом образе они об одном и
    # том же файле кита.
    'patch source escapes every captured name':
        'читает tweakcc-patch.js, а не образ',
    'patch source keeps both dispatcher shapes':
        'читает tweakcc-patch.js, а не образ',
    # Пинит СТОКОВУЮ форму и краснеет, когда её испортит наш свип классов.
    'Vertex project resolution intact (fork-sweep tripwire)':
        'пинит стоковую форму -- зелена на стоке по замыслу',
}

out = subprocess.run([sys.executable, block, img, patch_src],
                     capture_output=True, text=True)
green, red = [], []
for line in out.stdout.splitlines():
    line = line.strip()
    if line.startswith('[OK] '):
        green.append(line[5:])
    elif line.startswith('[FAIL] '):
        red.append(line[7:])
if not green and not red:
    sys.exit('ПОЛ НЕ ИЗМЕРЕН: блок проверок не назвал ни одной проверки\n'
             + (out.stdout or out.stderr)[-2000:])

extra = [n for n in green if n not in DECLARED]
missing = [n for n in DECLARED if n not in green]
if extra or missing:
    print('ПОЛ ПРОВЕРОК НЕ СОШЁЛСЯ (образ: %s)' % img)
    for n in extra:
        print('  зелена на стоке, а не объявлена: %s' % n)
        print('    -- её порог лежит НИЖЕ стокового пола: она не может упасть')
    for n in missing:
        print('  объявлена зелёной на стоке, но красна: %s' % n)
        print('    -- объявление устарело; прочитать причину заново')
    sys.exit(1)
print('ПОЛ ПРОВЕРОК СОШЁЛСЯ: на пристинном образе зелёных %d из %d, все объявлены'
      % (len(green), len(green) + len(red)))
FLOOR_PY
