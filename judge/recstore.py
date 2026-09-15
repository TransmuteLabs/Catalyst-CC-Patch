#!/usr/bin/env python3
"""Разрешитель «поле rec журнала -> файл улики».

Журнал пишет в rec имя БЕЗ .gz (compact.py:188), а большинство улик на
диске лежит сжатыми; знание о суффиксе жило в трёх местах по отдельности.
Единственный дом этого знания -- здесь.

Коды выхода:
  0  улика разрешена (ценз: все указатели разрешимы)
  1  улика не найдена (ценз: есть неразрешимые; до десяти имён)
  2  дом улик отсутствует или пуст (ценз: указателей ноль) -- прибор
     не может мерить, это НЕ «улика не найдена»
"""
import glob
import gzip
import io
import json
import os
import sys

DEFAULT_RECORDS = os.path.expanduser('~/.claude/probes/judge/records')


def _records_dir(records_dir=None):
    # Лестница: явный параметр -> $JUDGE_RECORDS_DIR -> DEFAULT_RECORDS.
    if records_dir is None:
        records_dir = os.environ.get('JUDGE_RECORDS_DIR') or DEFAULT_RECORDS
    return os.path.expanduser(records_dir)


def resolve(rec, records_dir=None):
    if not isinstance(rec, str) or not rec:
        return None
    # Порядок кандидатов: точное имя, затем имя + '.gz'. Обратного
    # отсечения (.gz из указателя -> несжатый файл) НЕТ: таких пар журнал
    # не пишет, а перекрёстное разрешение спрятало бы опечатку вместо
    # честного None.
    name = os.path.basename(rec)
    d = _records_dir(records_dir)
    for candidate in (name, name + '.gz'):
        path = os.path.join(d, candidate)
        if os.path.isfile(path):
            return os.path.abspath(path)
    return None


def open_rec(rec, records_dir=None):
    path = resolve(rec, records_dir)
    if path is None:
        raise FileNotFoundError(
            f'улика не найдена: {rec} (дом: {_records_dir(records_dir)})')
    if path.endswith('.gz'):
        return gzip.open(path, 'rt', encoding='utf-8')
    return io.open(path, 'rt', encoding='utf-8')


def load_rec(rec, records_dir=None):
    with open_rec(rec, records_dir) as fh:
        return json.load(fh)


def _journal_values(records_dir):
    """Все значения rec из journal.jsonl и journal.jsonl.shard.* родителя дома.

    Неразбирающаяся строка пропускается и называется -- она не входит в
    знаменатель ценза молча: счёт, не знающий о потерянном, ложен.
    """
    parent = os.path.dirname(os.path.abspath(_records_dir(records_dir)))
    seq = []
    torn = 0
    paths = [os.path.join(parent, 'journal.jsonl')]
    paths += sorted(glob.glob(os.path.join(parent, 'journal.jsonl.shard.*')))
    for path in paths:
        try:
            fh = io.open(path, 'rt', encoding='utf-8')
        except FileNotFoundError:
            continue
        with fh:
            for line in fh:
                s = line.strip()
                if not s:
                    continue
                try:
                    obj = json.loads(s)
                except ValueError:
                    torn += 1
                    continue
                rec = obj.get('rec') if isinstance(obj, dict) else None
                if isinstance(rec, str) and rec:
                    seq.append(rec)
    if torn:
        sys.stderr.write(f'ВНИМАНИЕ: строк журнала не разобрано: {torn}\n')
    return seq


def census(records_dir=None):
    seq = _journal_values(records_dir)
    if not seq:
        print('указателей 0, точным именем 0, суффиксом .gz 0, не разрешается 0')
        return 2
    exact = suffixed = missing = 0
    missed_names = []
    for rec in seq:
        got = resolve(rec, records_dir)
        if got is None:
            missing += 1
            if len(missed_names) < 10:
                missed_names.append(rec)
        elif os.path.basename(got) == os.path.basename(rec):
            exact += 1
        else:
            suffixed += 1
    print(f'указателей {len(seq)}, точным именем {exact}, '
          f'суффиксом .gz {suffixed}, не разрешается {missing}')
    if missing:
        for name in missed_names:
            print('не разрешается: ' + name)
        return 1
    return 0


def _run_single(rec, cat):
    d = _records_dir()
    if not os.path.isdir(d) or not os.listdir(d):
        print(f'ОТКАЗ: дом улик отсутствует или пуст: {d}')
        return 2
    path = resolve(rec)
    if path is None:
        print(f'ОТКАЗ: улика не найдена: {rec} (дом: {d})')
        return 1
    print(path)
    if cat:
        with open_rec(rec) as fh:
            sys.stdout.write(fh.read())
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if '--census' in argv:
        return census()
    cat = '--cat' in argv
    rest = [a for a in argv if a != '--cat']
    if len(rest) != 1:
        sys.stderr.write('использование: recstore.py <rec> [--cat] | --census\n')
        return 1
    return _run_single(rest[0], cat)


if __name__ == '__main__':
    sys.exit(main())
