#!/usr/bin/env python3
"""Зуб разрешителя recstore: каждая проверка обязана уметь краснеть.

Отрицательный контроль -- часть предмета, а не украшение: зелёный зуб,
ни разу не красневший, не отличает правильный resolve от наивного
(только точное имя), поэтому здесь наивная форма подставляется явно и
её краснота проверяется так же строго, как зелёнота настоящей.
"""
import gzip
import json
import os
import shutil
import subprocess
import sys
import tempfile

JUDGE_HOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, JUDGE_HOME)
import recstore

RESULTS = []


def check(name, ok, detail=''):
    RESULTS.append((name, bool(ok)))
    mark = 'ok   ' if ok else 'FAIL '
    print(mark + name + (f' :: {detail}' if detail else ''))


def main():
    tmp = tempfile.mkdtemp(prefix='recstore-tooth-')
    try:
        body = {'kind': 'probe', 'n': 1}
        with open(os.path.join(tmp, 'X.json'), 'w', encoding='utf-8') as fh:
            json.dump(body, fh)
        with gzip.open(os.path.join(tmp, 'Y.json.gz'), 'wt', encoding='utf-8') as fh:
            json.dump(body, fh)
        # Z.json сознательно не создаётся: None на отсутствующей улике --
        # законный ответ, который вызывающий обязан уметь отличить от пути.

        check('resolve: точное имя X.json',
              recstore.resolve('X.json', tmp) == os.path.join(tmp, 'X.json'))
        check('resolve: суффикс Y.json -> Y.json.gz',
              recstore.resolve('Y.json', tmp) == os.path.join(tmp, 'Y.json.gz'))
        check('resolve: отсутствующая Z.json -> None',
              recstore.resolve('Z.json', tmp) is None)
        check('resolve: значение-путь сводится к basename',
              recstore.resolve(os.path.join('чужой', 'дом', 'X.json'), tmp)
              == os.path.join(tmp, 'X.json'))

        check('load_rec: несжатая форма отдаёт структуру',
              recstore.load_rec('X.json', tmp) == body)
        check('load_rec: сжатая форма отдаёт ту же структуру',
              recstore.load_rec('Y.json', tmp) == body)
        try:
            recstore.open_rec('Z.json', tmp)
            check('open_rec: отсутствующая -> FileNotFoundError', False)
        except FileNotFoundError as exc:
            check('open_rec: отсутствующая -> FileNotFoundError',
                  'Z.json' in str(exc), f'имя не названо: {exc!r}')

        # Отрицательный контроль: подмена наивной формой (только точное
        # имя) обязана сломать зеркальную проверку -- иначе зуб не отличил
        # бы правильный resolve от дефектного и его зелень пуста.
        probe = lambda: recstore.resolve('Y.json', tmp) is not None
        check('отрицательный контроль: настоящая форма зеркальную проверку проходит',
              probe())
        real_resolve = recstore.resolve

        def naive_resolve(rec, records_dir=None):
            d = os.path.expanduser(records_dir or recstore.DEFAULT_RECORDS)
            p = os.path.join(d, os.path.basename(rec))
            return os.path.abspath(p) if os.path.isfile(p) else None

        recstore.resolve = naive_resolve
        try:
            naive_red = not probe()
        finally:
            recstore.resolve = real_resolve
        if naive_red:
            print('отрицательный контроль: наивная форма resolve (только точное имя) '
                  'покраснела -- зеркальная проверка Y.json -> Y.json.gz на ней провалилась')
        else:
            print('отрицательный контроль НЕ сработал: наивная форма осталась зелёной')
        check('отрицательный контроль: наивная форма покраснела', naive_red)

        journal = os.path.join(os.path.dirname(recstore.DEFAULT_RECORDS),
                               'journal.jsonl')
        if not os.path.isfile(journal):
            check('census по живому журналу', False,
                  f'ПРОПУЩЕНО (и это не зелено): живого журнала нет: {journal}')
        else:
            proc = subprocess.run(
                [sys.executable, os.path.join(JUDGE_HOME, 'recstore.py'), '--census'],
                capture_output=True, text=True)
            line = (proc.stdout or '').strip().splitlines()
            count_line = line[0] if line else ''
            check('census по живому журналу: код 0', proc.returncode == 0,
                  f'rc={proc.returncode} stdout={proc.stdout!r} stderr={proc.stderr!r}')
            check('census по живому журналу: строка счёта на месте',
                  count_line.startswith('указателей '), count_line)
            print('census: ' + count_line)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    failed = [name for name, ok in RESULTS if not ok]
    print(f'проверок: {len(RESULTS)}, провалено: {len(failed)}')
    if failed:
        for name in failed:
            print('FAIL ' + name)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
