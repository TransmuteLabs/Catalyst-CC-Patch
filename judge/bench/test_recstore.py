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
    fixtures = []
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

        # CONSTRAINT: ценз идёт по СВОЕЙ фикстуре, а не по живому журналу
        # машины. Наличие журнала -- свойство ПЛОЩАДКИ (на Linux-стороне
        # судья не работает вовсе), и зуб, читающий его, меряет машину, а не
        # код: на площадке без журнала он краснеет по построению и роняет
        # гейт сборки.
        # CONSTRAINT: дом улик подставляется через JUDGE_RECORDS_DIR, потому
        # что main() зовёт census() БЕЗ аргумента -- лестница окружения
        # (recstore._records_dir) есть единственный вход в фикстуру.
        # CONSTRAINT: строка счёта сверяется ТОЧНЫМ равенством. Префикс
        # «указателей » проходил бы при любом счёте, и зуб был бы вакуумным.
        def census_of(fx_records):
            return subprocess.run(
                [sys.executable, os.path.join(JUDGE_HOME, 'recstore.py'),
                 '--census'],
                capture_output=True, text=True,
                env=dict(os.environ, JUDGE_RECORDS_DIR=fx_records))

        def census_fixture(pointers, files, shard=()):
            fx = tempfile.mkdtemp(prefix='recstore-census-')
            fixtures.append(fx)
            recs = os.path.join(fx, 'records')
            os.mkdir(recs)
            for name in files:
                path = os.path.join(recs, name)
                if name.endswith('.gz'):
                    with gzip.open(path, 'wt', encoding='utf-8') as fh:
                        json.dump(body, fh)
                else:
                    with open(path, 'w', encoding='utf-8') as fh:
                        json.dump(body, fh)
            with open(os.path.join(fx, 'journal.jsonl'), 'w',
                      encoding='utf-8') as fh:
                for rec in pointers:
                    fh.write(json.dumps({'rec': rec}) + '\n')
            if shard:
                with open(os.path.join(fx, 'journal.jsonl.shard.001'), 'w',
                          encoding='utf-8') as fh:
                    for rec in shard:
                        fh.write(json.dumps({'rec': rec}) + '\n')
            return recs

        def census_lines(proc):
            out = (proc.stdout or '').strip().splitlines()
            return out, (out[0] if out else '')

        def census_detail(proc):
            return (f'rc={proc.returncode} stdout={proc.stdout!r} '
                    f'stderr={proc.stderr!r}')

        # Под-случай 1: всё разрешается. C.json объявлен ШАРДОМ -- без чтения
        # шардов знаменатель стал бы 2, и это единственное место, где ветка
        # шардов журнала попадает под замер.
        recs = census_fixture(['A.json', 'B.json'],
                              ['A.json', 'B.json.gz', 'C.json'],
                              shard=['C.json'])
        proc = census_of(recs)
        _, count_line = census_lines(proc)
        check('census/всё разрешается: код 0', proc.returncode == 0,
              census_detail(proc))
        check('census/всё разрешается: счёт дословно',
              count_line == ('указателей 3, точным именем 2, '
                             'суффиксом .gz 1, не разрешается 0'),
              census_detail(proc))
        print('census/всё разрешается: ' + count_line)

        # Под-случай 2: неразрешимый указатель. Ветка обязана и посчитать
        # его, и НАЗВАТЬ: молчаливая недостача неотличима от чистого дома.
        recs = census_fixture(['A.json', 'MISSING.json'], ['A.json'])
        proc = census_of(recs)
        out, count_line = census_lines(proc)
        check('census/недостача: код 1', proc.returncode == 1,
              census_detail(proc))
        check('census/недостача: счёт дословно',
              count_line == ('указателей 2, точным именем 1, '
                             'суффиксом .gz 0, не разрешается 1'),
              census_detail(proc))
        check('census/недостача: имя названо',
              'не разрешается: MISSING.json' in out, census_detail(proc))

        # Под-случай 3: пустой журнал -- отдельный код 2, а не «ноль ошибок».
        recs = census_fixture([], [])
        proc = census_of(recs)
        _, count_line = census_lines(proc)
        check('census/пустой журнал: код 2', proc.returncode == 2,
              census_detail(proc))
        check('census/пустой журнал: счёт дословно',
              count_line == ('указателей 0, точным именем 0, '
                             'суффиксом .gz 0, не разрешается 0'),
              census_detail(proc))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        for fx in fixtures:
            shutil.rmtree(fx, ignore_errors=True)

    failed = [name for name, ok in RESULTS if not ok]
    print(f'проверок: {len(RESULTS)}, провалено: {len(failed)}')
    if failed:
        for name in failed:
            print('FAIL ' + name)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
