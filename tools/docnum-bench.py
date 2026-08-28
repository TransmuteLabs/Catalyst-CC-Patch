#!/usr/bin/env python3
"""Зубы гейта чисел (шаг 0d конвейера).

Гейт сам по себе умеет молчать: он молчал трижды, и каждую дыру находили
руками, а не им. Внутри гейта живёт положительный контроль грамматики
(синтетические тексты с известным ответом), но он ничего не говорит о
СВЯЗКЕ гейта с настоящим деревом -- с README, с константами стендов, с
выбором владельца по ближайшему имени. Это она.

Порядок такой: сперва контроль без мутации (пристинный кит обязан быть
зелёным -- иначе краснеет что угодно и стенд ничего не доказывает), затем
каждая записанная мутация по очереди, каждая обязана покраснить гейт СВОЕЙ
причиной.

Гейт вырезается из конвейера по якорю. Якорь пропал -- отказ, а не тихий
пропуск: молча пропущенный стенд это ровно та тишина, ради которой он писан.

Коды выхода (подмножество общей таблицы кита -- см. шапку claude-patch-all.sh):
  0  каждая записанная мутация покраснела своей причиной
  1  зубы не держатся: мутация прошла молча или покраснела ЧУЖОЙ причиной
  2  прибор не может мерить: нет таблицы, строка не о пяти полях, якорь гейта
     пропал или встречается не один раз, либо ПРИСТИННЫЙ кит уже красный --
     контроль провален, и мутация ничего не докажет
  4  длина таблицы не равна объявленной в EXPECTED_MUTATIONS
Один код на два ответа уже стоил кита: вызывающий печатал «мутация не
покраснела» на КАЖДЫЙ ненулевой, включая пропавший якорь (раунд 18, F-9).
"""
import io
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(HERE)
TABLE = os.path.join(HERE, 'docnum-mutations.tsv')
PIPELINE = 'claude-patch-all.sh'
ANCHOR = 'python3 - "$0" <<\'PYDOCS\'\n'
END = '\nPYDOCS\n'
EXPECTED_MUTATIONS = 37


def read(path):
    return io.open(path, encoding='utf-8').read()


def say(message):
    print('docnum-bench: ' + message, flush=True)


def load():
    if not os.path.exists(TABLE):
        say('ОТКАЗ -- нет таблицы мутаций %s' % TABLE)
        sys.exit(2)
    rows = []
    for line in read(TABLE).splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        parts = line.split('\t')
        if len(parts) != 5:
            say('ОТКАЗ -- строка таблицы не о пяти полях: %r' % line)
            sys.exit(2)
        rows.append(parts)
    return rows


def carve(kit):
    """Гейт как отдельный исполняемый файл, вырезанный из конвейера."""
    source = read(os.path.join(kit, PIPELINE))
    if ANCHOR not in source:
        say('ОТКАЗ -- якорь гейта чисел пропал из %s' % PIPELINE)
        sys.exit(2)
    if source.count(ANCHOR) != 1:
        say('ОТКАЗ -- якорь гейта чисел встречается %d раз в %s: неизвестно, '
            'какое тело проверяется' % (source.count(ANCHOR), PIPELINE))
        sys.exit(2)
    start = source.index(ANCHOR) + len(ANCHOR)
    if END not in source[start:]:
        say('ОТКАЗ -- конец гейта чисел не найден в %s' % PIPELINE)
        sys.exit(2)
    body = source[start:source.index(END, start)]
    path = os.path.join(kit, '.docnum-gate.py')
    io.open(path, 'w', encoding='utf-8').write(body)
    return path


def run_gate(kit, gate):
    done = subprocess.run([sys.executable, gate, os.path.join(kit, PIPELINE)],
                          capture_output=True, text=True)
    return done.returncode, (done.stdout or '') + (done.stderr or '')


def main():
    rows = load()
    work = tempfile.mkdtemp(prefix='docnum-bench.')
    try:
        kit = os.path.join(work, 'kit')
        shutil.copytree(KIT, kit, ignore=shutil.ignore_patterns('.git'))
        gate = carve(kit)

        code, out = run_gate(kit, gate)
        if code != 0:
            say('КОНТРОЛЬ ПРОВАЛЕН -- пристинный кит уже красный, мутации ничего')
            say('не докажут. Вывод гейта:')
            for line in out.splitlines():
                print('    ' + line)
            # Класс 2: измерения не было. Прежде здесь стоял код 3, а 3 в
            # таблице кита значит «замок держит другой живой прогон --
            # повторить позже»; повтор тут не помогает никогда (раунд 19, A-4).
            return 2
        say('КОНТРОЛЬ без мутации: ЗЕЛЁНО')

        reddened = 0
        for name, rel, old, new, want in rows:
            target = os.path.join(kit, rel)
            if not os.path.exists(target):
                say('МУТАЦИЯ %s: FAIL -- нет файла %s' % (name, rel))
                continue
            pristine = read(target)
            seen = pristine.count(old)
            if seen == 0:
                say('МУТАЦИЯ %s: FAIL -- вход не найден дословно в %s' % (name, rel))
                continue
            if seen != 1:
                say('МУТАЦИЯ %s: FAIL -- вход встречается %d раз в %s: мутация '
                    'подтвердилась бы по теневому совпадению' % (name, seen, rel))
                continue
            io.open(target, 'w', encoding='utf-8').write(pristine.replace(old, new))
            # Гейт вырезается заново: мутация могла править сам гейт.
            code, out = run_gate(kit, carve(kit))
            io.open(target, 'w', encoding='utf-8').write(pristine)
            if code == 0:
                say('МУТАЦИЯ %s: ЗЕЛЁНАЯ -- гейт её не увидел' % name)
            elif want not in out:
                say('МУТАЦИЯ %s: КРАСНАЯ НЕ ПО ТОЙ ПРИЧИНЕ (нет «%s»):' % (name, want))
                for line in out.splitlines():
                    print('    ' + line)
            else:
                say('МУТАЦИЯ %s: RED' % name)
                reddened += 1

        say('ИТОГ мутаций=%d покраснели=%d' % (len(rows), reddened))
        if len(rows) != EXPECTED_MUTATIONS:
            say('ОТКАЗ -- в таблице %d строк, объявлено %d'
                % (len(rows), EXPECTED_MUTATIONS))
            return 4
        return 0 if reddened == len(rows) else 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
