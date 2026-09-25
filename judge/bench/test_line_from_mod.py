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

    line = compact._line_from_mod(dict(base, sid=SID), 'mod-a.json', 'judge')
    check('улика с sid -> строка несёт sid тем же значением',
          line.get('sid') == SID, f'sid в строке: {line.get("sid")!r}')

    line = compact._line_from_mod(dict(base), 'mod-b.json', 'judge')
    check('улика без sid -> ключа sid в строке нет вовсе',
          'sid' not in line, f'есть ключ sid: {"sid" in line}')

    line = compact._line_from_mod(dict(base, sid='sid-unavailable'),
                                  'mod-c.json', 'judge')
    check('sentinel "sid-unavailable" доезжает дословно',
          line.get('sid') == 'sid-unavailable',
          f'sid в строке: {line.get("sid")!r}')

    # Отрицательный контроль: подмена проектора формой без переноса sid
    # обязана сломать первую проверку -- иначе зуб не отличил бы перенос
    # поля от молчаливой потери и его зелень пуста.
    probe = lambda: compact._line_from_mod(dict(base, sid=SID),
                                           'mod-a.json', 'judge').get('sid') == SID
    real = compact._line_from_mod

    def line_without_sid(rec, filename, probe):
        line = real(rec, filename, probe)
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

    # --- #374: класс свёртки -- ОДИН дом --------------------------------
    #
    # CONSTRAINT: зуб на пробу "form" -- главный в этой группе. Снятая
    # литеральная таблица знала только судью и вернула бы REFUSE как 'skip';
    # дом формы объявляет REFUSE свёрнутым. Возврат второго дома краснеет
    # ровно здесь.
    line = compact._line_from_mod(
        dict(base, outcome='block_not_enforced'), 'mod-d.json', 'judge')
    check('готовый класс улики едет ДОСЛОВНО, без пересчёта',
          line.get('outcome') == 'block_not_enforced',
          f'outcome: {line.get("outcome")!r}')

    line = compact._line_from_mod(dict(base), 'mod-e.json', 'judge')
    check('улика без класса: BLOCK судьи взят из дома как block',
          line.get('outcome') == 'block', f'outcome: {line.get("outcome")!r}')

    line = compact._line_from_mod(dict(base, kind='OK'), 'mod-f.json', 'judge')
    check('улика без класса: OK судьи взят из дома как ok',
          line.get('outcome') == 'ok', f'outcome: {line.get("outcome")!r}')

    line = compact._line_from_mod(dict(base, kind='REFUSE'), 'mod-g.json', 'form')
    check('проба form: REFUSE свёрнут по ДОМУ ФОРМЫ (литеральная таблица '
          'дала бы skip)',
          line.get('outcome') == 'block', f'outcome: {line.get("outcome")!r}')

    line = compact._line_from_mod(dict(base, kind='TIMEOUT'), 'mod-h.json', 'judge')
    check('служебный исход остаётся литеральным: TIMEOUT -> skip',
          line.get('outcome') == 'skip', f'outcome: {line.get("outcome")!r}')

    refused = False
    try:
        compact._line_from_mod(dict(base, kind=None), 'mod-i.json', 'judge')
    except SystemExit as exc:
        refused = (exc.code == 2)
    check('улика без вида -- ОТКАЗ прибора кодом 2, а не тихий skip',
          refused, f'отказ: {refused}')

    # --- #393-A2-FIX4: t0 вне диапазона платформенных часов ------------------
    line = compact._line_from_mod(dict(base, t0=1e308), 'mod-j.json', 'judge')
    check('t0 = 1e308 не роняет проектор: t нет, t0Invalid несёт значение',
          't' not in line and line.get('t0Invalid') == '1e+308',
          f't0Invalid: {line.get("t0Invalid")!r}')

    line = compact._line_from_mod(dict(base, t0=float('inf')), 'mod-k.json', 'judge')
    check('t0 = inf не роняет проектор: t нет, t0Invalid несёт значение',
          't' not in line and line.get('t0Invalid') == 'inf',
          f't0Invalid: {line.get("t0Invalid")!r}')

    line = compact._line_from_mod(dict(base, t0=1700000000000), 'mod-l.json', 'judge')
    check('обычное t0 даёт t и не даёт t0Invalid',
          line.get('t') == '2023-11-14T22:13:20.000Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    # --- #393-A2-FIX5: время улики проецируется как есть ----------------------
    line = compact._line_from_mod(dict(base, t0=True), 'mod-m.json', 'judge')
    check('t0=True (bool) -> t нет, t0Invalid несёт repr',
          't' not in line and line.get('t0Invalid') == 'True',
          f't0Invalid: {line.get("t0Invalid")!r}')

    line = compact._line_from_mod(dict(base, t0=False), 'mod-n.json', 'judge')
    check('t0=False (bool) -> t нет, t0Invalid несёт repr',
          't' not in line and line.get('t0Invalid') == 'False',
          f't0Invalid: {line.get("t0Invalid")!r}')

    line = compact._line_from_mod(dict(base, t0=float('nan')), 'mod-o.json', 'judge')
    check('t0=NaN -> t нет, t0Invalid несёт repr',
          't' not in line and line.get('t0Invalid') == 'nan',
          f't0Invalid: {line.get("t0Invalid")!r}')

    line = compact._line_from_mod(dict(base, t0='1700000000000'), 'mod-p.json', 'judge')
    check('t0 строкой -> t нет, t0Invalid несёт repr',
          't' not in line and line.get('t0Invalid') == "'1700000000000'",
          f't0Invalid: {line.get("t0Invalid")!r}')

    line = compact._line_from_mod(dict(base, t0={}), 'mod-q.json', 'judge')
    check('t0 не-число (пустой словарь) -> t нет, t0Invalid несёт repr',
          't' not in line and line.get('t0Invalid') == '{}',
          f't0Invalid: {line.get("t0Invalid")!r}')

    line = compact._line_from_mod(dict(base, t0=0), 'mod-r.json', 'judge')
    check('t0=0 -- конечное число диапазона Date: t есть, t0Invalid нет',
          line.get('t') == '1970-01-01T00:00:00.000Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    line = compact._line_from_mod(dict(base, t0=-1000), 'mod-s.json', 'judge')
    check('t0=-1000 -- конечное число диапазона Date: t есть, t0Invalid нет',
          line.get('t') == '1969-12-31T23:59:59.000Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    line = compact._line_from_mod(dict(base, t0=8.64e15 + 1), 'mod-t.json', 'judge')
    check('t0 за границей Date -> t0Invalid несёт repr',
          't' not in line and line.get('t0Invalid') == '8640000000000001.0',
          f't0Invalid: {line.get("t0Invalid")!r}')

    # --- #393-A2-FIX6: форма toISOString без обрыва ---------------------------
    line = compact._line_from_mod(dict(base, t0=10**309), 'mod-f6-01.json', 'judge')
    check('t0 = 10**309 (int за пределами float) -> t нет, t0Invalid несёт repr',
          't' not in line and line.get('t0Invalid') == repr(10**309),
          f't0Invalid: {line.get("t0Invalid")!r}')

    line = compact._line_from_mod(dict(base, t0=-(10**400)), 'mod-f6-02.json', 'judge')
    check('t0 = -(10**400) (int за пределами float) -> t нет, t0Invalid несёт repr',
          't' not in line and line.get('t0Invalid') == repr(-(10**400)),
          f't0Invalid: {line.get("t0Invalid")!r}')

    line = compact._line_from_mod(dict(base, t0=1500), 'mod-f6-03.json', 'judge')
    check('t0 = 1500 -> t несёт миллисекунды, t0Invalid нет',
          line.get('t') == '1970-01-01T00:00:01.500Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    line = compact._line_from_mod(dict(base, t0=-1500), 'mod-f6-04.json', 'judge')
    check('t0 = -1500 (до эпохи) -> t несёт миллисекунды, t0Invalid нет',
          line.get('t') == '1969-12-31T23:59:58.500Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    line = compact._line_from_mod(dict(base, t0=1500.7), 'mod-f6-05.json', 'judge')
    check('t0 = 1500.7 -> мс усечены к нулю: t есть, t0Invalid нет',
          line.get('t') == '1970-01-01T00:00:01.500Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    line = compact._line_from_mod(dict(base, t0=-1500.7), 'mod-f6-06.json', 'judge')
    check('t0 = -1500.7 -> мс усечены к нулю: t есть, t0Invalid нет',
          line.get('t') == '1969-12-31T23:59:58.500Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    line = compact._line_from_mod(dict(base, t0=1700000000123), 'mod-f6-07.json', 'judge')
    check('t0 = 1700000000123 -> t несёт мс 123, t0Invalid нет',
          line.get('t') == '2023-11-14T22:13:20.123Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    line = compact._line_from_mod(dict(base, t0=8.64e15), 'mod-f6-08.json', 'judge')
    check('t0 = 8.64e15 (верхняя граница Date) -> t со знаком + и шестью цифрами года',
          line.get('t') == '+275760-09-13T00:00:00.000Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    line = compact._line_from_mod(dict(base, t0=-8.64e15), 'mod-f6-09.json', 'judge')
    check('t0 = -8.64e15 (нижняя граница Date) -> t со знаком - и шестью цифрами года',
          line.get('t') == '-271821-04-20T00:00:00.000Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    line = compact._line_from_mod(dict(base, t0=-62167219200000), 'mod-f6-10.json', 'judge')
    check('t0 = год 0 -> t с четырёхзначным нулевым годом',
          line.get('t') == '0000-01-01T00:00:00.000Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    line = compact._line_from_mod(dict(base, t0=-62198755200000), 'mod-f6-11.json', 'judge')
    check('t0 = год -1 -> t со знаком минус и шестью цифрами года',
          line.get('t') == '-000001-01-01T00:00:00.000Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    line = compact._line_from_mod(dict(base, t0=253402300800000), 'mod-f6-12.json', 'judge')
    check('t0 = год 10000 -> t со знаком плюс и шестью цифрами года',
          line.get('t') == '+010000-01-01T00:00:00.000Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    line = compact._line_from_mod(dict(base, t0=-61978089599500), 'mod-f6-13.json', 'judge')
    check('t0 = -61978089599500 -> t несёт мс 500, t0Invalid нет',
          line.get('t') == '0005-12-29T00:00:00.500Z' and 't0Invalid' not in line,
          f't: {line.get("t")!r}')

    no_t0 = dict(base)
    del no_t0['t0']
    line = compact._line_from_mod(no_t0, 'mod-u.json', 'judge')
    check('без t0 -- ни t, ни t0Invalid',
          't' not in line and 't0Invalid' not in line,
          f't: {line.get("t")!r}, t0Invalid: {line.get("t0Invalid")!r}')

    # CONSTRAINT: отказ платформенных часов (gmtime) -- значение в t0Invalid,
    # а не падение проектора; подмена возвращается на место в finally.
    orig_gmtime = compact.time.gmtime
    try:
        for exc_type in (ValueError, OSError):
            def raising_gmtime(_ts, _et=exc_type):
                raise _et('scripted gmtime refusal')
            compact.time.gmtime = raising_gmtime
            try:
                line = compact._line_from_mod(dict(base, t0=1700000000000),
                                              'mod-v.json', 'judge')
                ok = 't' not in line and line.get('t0Invalid') == '1700000000000'
                detail = f't0Invalid: {line.get("t0Invalid")!r}'
            except Exception as exc:
                ok = False
                detail = f'поднялось исключение: {type(exc).__name__}: {exc}'
            check(f'отказ gmtime ({exc_type.__name__}) -> t нет, t0Invalid несёт repr',
                  ok, detail)
    finally:
        compact.time.gmtime = orig_gmtime

    failed = [name for name, ok in RESULTS if not ok]
    print(f'проверок: {len(RESULTS)}, провалено: {len(failed)}')
    if failed:
        for name in failed:
            print('FAIL ' + name)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
