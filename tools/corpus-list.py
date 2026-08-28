#!/usr/bin/env python3
"""Единственный дом ФОРМАТА списка корпуса.

Формат читали два инструмента, каждый своим `while read`, и обе трактовки
разошлись: строка без пина у свипа была отказом, а у наполнителя -- поводом
скачать и записать пин; лишнее четвёртое поле оба молча проглатывали; одна и
та же версия под двумя метками считалась двумя измеренными версиями, хотя
файл на диске один. Разбор переехал сюда: кто читает список, читает ЭТОТ
разбор, и «все N версий измерены» снова значит N разных версий.

Печатает по строке на запись: метка, версия, пин -- через табуляцию.
Отказ -- ненулевой код и причина на stderr; частичного вывода не бывает.

Пин платформозависим: пакет реестра свой для каждой пары ОС+архитектура, и
корпус, набранный на одной машине, на другой отвергался бы поштучно с текстом
про подмену образа. Поэтому список НАЗЫВАЕТ свою платформу, а расхождение
объявляется своей причиной.
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
PIN = re.compile(r'^[0-9a-fA-F]{64}$')
VERSION = re.compile(r'^[0-9][0-9.]*$')
PLATFORM = re.compile(r'^#\s*platform:\s*(\S+)\s*$')


def die(message):
    sys.stderr.write('СПИСОК КОРПУСА ОТКАЗ: %s\n' % message)
    raise SystemExit(1)


def main():
    if len(sys.argv) != 2:
        die('нужен ровно один аргумент -- путь к списку')
    path = sys.argv[1]
    if not os.path.exists(path):
        die('нет файла %s' % path)
    try:
        import claude_patch
        here_platform = claude_patch.npm_platform_pkg()
    except Exception as exc:                      # noqa: BLE001
        die('не определить платформу (%s)' % exc)

    declared, rows, labels, versions = None, [], {}, {}
    for number, raw in enumerate(io.open(path, encoding='utf-8'), 1):
        # \r из строки снимается ЗДЕСЬ: попав в пин, он превращал совпадающий
        # хеш в расхождение, и отказ называл подмену там, где был перевод строки.
        line = raw.replace('\r', '').rstrip('\n')
        marker = PLATFORM.match(line)
        if marker:
            declared = marker.group(1)
            continue
        line = re.sub(r'#.*', '', line).strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 3:
            die('строка %d: полей %d, а формат -- ровно три (метка, версия, пин; '
                'пин «-», если ещё не записан)' % (number, len(parts)))
        label, version, pin = parts
        if not VERSION.match(version):
            die('строка %d: «%s» не похоже на номер версии' % (number, version))
        if pin != '-' and not PIN.match(pin):
            die('строка %d: пин «%s» -- не 64 шестнадцатеричных знака и не «-»'
                % (number, pin))
        if label in labels:
            die('строка %d: метка «%s» уже была в строке %d'
                % (number, label, labels[label]))
        if version in versions:
            die('строка %d: версия %s уже была в строке %d -- один файл считался '
                'бы двумя измеренными версиями' % (number, version, versions[version]))
        labels[label], versions[version] = number, number
        # Пин приводится к нижнему регистру ОДИН раз, здесь: тот же хеш в другом
        # регистре -- тот же хеш, а сырое сравнение строк объявляло его подменой.
        rows.append((label, version, pin.lower()))

    if declared is None:
        die('в списке не названа платформа: добавьте строку «# platform: %s». '
            'Пин платформозависим, и без этой строки корпус с другой машины '
            'отвергался бы поштучно как подменённый' % here_platform)
    if declared != here_platform:
        die('список набран для платформы %s, а машина -- %s. Это не подмена '
            'образов: пакеты реестра для разных платформ разные, и пины к ним '
            'не относятся' % (declared, here_platform))
    if not rows:
        die('в списке нет ни одной версии')
    out = ''.join('%s\t%s\t%s\n' % row for row in rows)
    sys.stdout.write(out)


if __name__ == '__main__':
    main()
