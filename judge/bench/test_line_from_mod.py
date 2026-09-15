#!/usr/bin/env python3
"""Зуб на проектор _line_from_mod: перенос sid из улики в строку журнала.

Отрицательный контроль -- часть предмета, а не украшение: зелёный зуб,
ни разу не красневший, не отличает перенос поля от его молчаливой потери,
поэтому проектор подменяется формой без переноса sid и её краснота
проверяется так же строго, как зелёнота настоящей.

Инвариант разреза журнала: поля sid нет -- запись написана до фикса;
sid == "sid-unavailable" -- фикс на месте, поверхность отказала; иначе --
идентификатор носителя. Проектор НЕ подставляет sentinel сам: улика --
источник истины, у старой улики поля нет, и появиться из проектора оно
не может.
"""
import os
import sys

JUDGE_HOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, JUDGE_HOME)
import compact

RESULTS = []

SID = '9632494b-06c5-4812-868f-0ac3e2ca3530'


def check(name, ok, detail=''):
    RESULTS.append((name, bool(ok)))
    mark = 'ok   ' if ok else 'FAIL '
    print(mark + name + (f' :: {detail}' if detail else ''))


def main():
    base = {
        'kind': 'BLOCK', 'rest': 'r', 't0': 1700000000000,
        'tool': 'Bash', 'agent': '', 'dtMs': 3, 'used': 1, 'cls': 'c',
    }

    line = compact._line_from_mod(dict(base, sid=SID), 'mod-a.json')
    check('улика с sid -> строка несёт sid тем же значением',
          line.get('sid') == SID, f'sid в строке: {line.get("sid")!r}')

    line = compact._line_from_mod(dict(base), 'mod-b.json')
    check('улика без sid -> ключа sid в строке нет вовсе',
          'sid' not in line, f'есть ключ sid: {"sid" in line}')

    line = compact._line_from_mod(dict(base, sid='sid-unavailable'),
                                  'mod-c.json')
    check('sentinel "sid-unavailable" доезжает дословно',
          line.get('sid') == 'sid-unavailable',
          f'sid в строке: {line.get("sid")!r}')

    # Отрицательный контроль: подмена проектора формой без переноса sid
    # обязана сломать первую проверку -- иначе зуб не отличил бы перенос
    # поля от молчаливой потери и его зелень пуста.
    probe = lambda: compact._line_from_mod(dict(base, sid=SID),
                                           'mod-a.json').get('sid') == SID
    real = compact._line_from_mod

    def line_without_sid(rec, filename):
        line = real(rec, filename)
        line.pop('sid', None)
        return line

    compact._line_from_mod = line_without_sid
    try:
        red = not probe()
    finally:
        compact._line_from_mod = real
    if red:
        print('отрицательный контроль: проектор без переноса sid покраснел '
              '-- проверка «улика с sid» на подмене провалилась')
    else:
        print('отрицательный контроль НЕ сработал: подмена без sid '
              'осталась зелёной')
    check('отрицательный контроль: подмена без sid краснеет', red)

    failed = [name for name, ok in RESULTS if not ok]
    print(f'проверок: {len(RESULTS)}, провалено: {len(failed)}')
    if failed:
        for name in failed:
            print('FAIL ' + name)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
