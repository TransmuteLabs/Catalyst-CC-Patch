#!/usr/bin/env python3
"""ЕДИНСТВЕННЫЙ дом разбора карты «шаг -> проверки» (tools/our-step-checks.txt).

Карта отвечает на вопрос «какие проверки ведут выключенный шаг»: реестр
выключений (tools/our-steps-off.txt) несёт решение оператора, а проверяющая
сторона конвейера обязана знать о выключенном шаге ДО того, как его проверки
пойдут обычным путём и упадут «предмета нет» без объяснения.

Грамматика строки -- три поля через '|' (пробелы вокруг полей сняты):
  <имя шага ровно как в step('…')> | <id обработчика> | <имена проверок через ';'>
Поле проверок, равное '-', -- ОБЪЯВЛЕННОЕ отсутствие проверок: норма, а не
забытая строка -- дельта обязана быть объявляемой и отличимой от поломки.

CONSTRAINT: карта -- свойство КИТА, в отличие от реестра выключений: её
отсутствие, пустота или одни комментарии -- ОТКАЗ ПРИБОРА (код 2 у CLI), а не
норма: пустая карта значила бы потерю данных, а не решение оператора.

CONSTRAINT: разбор реестра выключений здесь НЕ дублируется -- имена записей
читает единственный дом разбора tools/steps-off-registry.js (режим --names);
вторая копия разбора расходилась бы с выровненными читателями молча.

Коды CLI --gate <реестр> <карта>:
  0  все записи реестра проведены в карту (печать «все проведены»)
  3  есть записи без строки карты: отказ называет шаг и требуемое действие
  2  отказ прибора: карта не читается, обработчик неизвестен коду, реестр
     не читается
"""
import subprocess
import sys
from pathlib import Path

# Диспетчер обработчиков живёт кодом в проверяющей стороне конвейера
# (claude-patch-all.sh: {'s26': _step26_verdict}); этот реестр -- имена, которые
# код ЗНАЕТ. Строка карты с неизвестным коду обработчиком -- отказ прибора:
# она обязана заставить волну, добавляющую запись реестра, добавить и
# обработчик, а не молча пойти в никуда.
KNOWN_HANDLERS = frozenset({'s26'})


class StepChecksError(Exception):
    """Отказ прибора: карта не читается как данные."""


def read_step_checks(path) -> dict:
    """Разбор карты: имя шага -> (id обработчика, [имена проверок]).

    Семантика разбора живёт ТОЛЬКО здесь; печать и коды возврата -- дело CLI.
    """
    try:
        text = Path(path).read_text(encoding='utf-8')
    except OSError as error:
        raise StepChecksError(f'карта шагов не читается: {path}: {error}')
    rows = {}
    seen = {}
    for number, line in enumerate(text.split('\n'), 1):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        parts = [part.strip() for part in line.split('|')]
        if len(parts) != 3 or not all(parts):
            raise StepChecksError(
                f'неразобранная строка {number} в {path}: нужны три поля '
                f"через '|' (имя шага | id обработчика | имена проверок "
                f"через ';', либо '-' как объявленное отсутствие)")
        name, handler, checks_field = parts
        if name in seen:
            raise StepChecksError(
                f'две строки на шаг {name!r} в {path} (строки {seen[name]} '
                f'и {number})')
        seen[name] = number
        if handler not in KNOWN_HANDLERS:
            raise StepChecksError(
                f'строка {number} в {path}: обработчик {handler!r} неизвестен '
                f'коду (известны: {", ".join(sorted(KNOWN_HANDLERS))})')
        if checks_field == '-':
            checks = []
        else:
            checks = [piece.strip() for piece in checks_field.split(';')]
            if not checks or any(not piece for piece in checks):
                raise StepChecksError(
                    f'строка {number} в {path}: поле проверок не может быть '
                    f"пустым -- отсутствие проверок объявляется знаком '-'")
        rows[name] = (handler, checks)
    if not rows:
        raise StepChecksError(
            f'карта шагов пуста или несёт только комментарии: {path} -- '
            f'карта есть свойство кита, её пустота -- потеря данных')
    return rows


def _read_registry_names(registry) -> list:
    """Имена записей реестра выключений -- из единственного дома разбора."""
    module = Path(__file__).resolve().parent / 'steps-off-registry.js'
    try:
        proc = subprocess.run(
            ['node', str(module), str(registry), '--names'],
            capture_output=True, text=True, errors='replace')
    except OSError as error:
        raise StepChecksError(f'нет node для чтения реестра: {error}')
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or '').strip()
        raise StepChecksError(
            f'реестр выключенных шагов не читается (rc={proc.returncode}): '
            f'{detail}')
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def gate(registry, map_path) -> int:
    """Гейт: каждая запись реестра обязана нести строку карты.

    0 -- все проведены; 3 -- есть непроведённые (отказ называет шаг и
    требуемое действие); 2 -- отказ прибора.
    """
    try:
        checks_map = read_step_checks(map_path)
        names = _read_registry_names(registry)
    except StepChecksError as error:
        print(f'ОТКАЗ ПРИБОРА: {error}', file=sys.stderr)
        return 2
    missing = [name for name in names if name not in checks_map]
    if missing:
        for name in missing:
            print(f'ГЕЙТ КАРТЫ ШАГОВ: запись реестра не проведена в карту -- '
                  f'шаг {name!r}: добавь строку '
                  f"'{name} | <id обработчика> | <проверки через ; либо ->' "
                  f'в {map_path}')
        return 3
    print(f'карта шагов: записей реестра {len(names)}, все проведены')
    return 0


def main(argv) -> int:
    if len(argv) == 4 and argv[1] == '--gate':
        return gate(argv[2], argv[3])
    print('использование: step-checks.py --gate <реестр our-steps-off.txt> '
          '<карта our-step-checks.txt>', file=sys.stderr)
    print('  коды: 0 -- все записи реестра проведены в карту; 3 -- есть '
          'непроведённые; 2 -- отказ прибора', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
